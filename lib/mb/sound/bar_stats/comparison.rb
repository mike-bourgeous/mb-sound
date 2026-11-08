module MB
  module Sound
    module BarStats
      # Two recordings (or two sections of one) compared bar by bar: per
      # bar the change of every measure (B minus A), each band's lag of B
      # behind A (Timing.lags: onset cross-correlation refined on the
      # waveform, per band, never the whole mix only), the worst bars
      # ranked with the measures that moved, likely causes by rule
      # (CAUSES), pass/fail against thresholds (THRESHOLDS; usable from
      # specs and scripts), and a plain-text narrative from the same data.
      #
      #     c = BarStats.compare('v13.flac', 'v15.flac', bpm: 140)
      #     c.worst(5)              # Bar entries, worst first
      #     c.causes.map(&:text)    # ["high band 66.0 ms late in ... a late bus or track", ...]
      #     c.pass?(lufs: 0.5)      # thresholds by measure
      #     c.check!(timing: 2)     # raises naming the failing bars
      #     puts c.narrative
      class Comparison
        # How far a per-band lag is searched (seconds either way).
        MAX_LAG = 0.125

        # Default thresholds by measure (units: ms for timing, LU or dB
        # for levels, dB/octave for tilt, a ratio for the centroid (0.15:
        # 15% either way), correlation units, and chroma distance, 1 minus
        # the cosine of the two bars' chroma).  A bar fails a measure when
        # the change reaches its threshold; nil skips a measure.
        THRESHOLDS = {
          timing: 5.0, lufs: 1.0, rms: 1.0, true_peak: 1.0, crest: 1.5, tail: 3.0,
          bands: 6.0, centroid: 0.15, tilt: 0.75, correlation: 0.2, width: 4.0, side: 4.0, chroma: 0.25,
        }.freeze

        # The measure group of each compared value (what a threshold key
        # covers).
        GROUP = {
          lag_low: :timing, lag_mid: :timing, lag_high: :timing,
          onset_low: :timing, onset_mid: :timing, onset_high: :timing,
          lufs: :lufs, rms: :rms, true_peak: :true_peak, crest: :crest, tail: :tail,
          centroid: :centroid, tilt: :tilt, correlation: :correlation, width: :width,
          side_low: :side, side_mid: :side, side_high: :side, chroma: :chroma,
        }.freeze

        # Levels under this (dB) count as silence in band comparisons.
        FLOOR_DB = -90.0

        # Beat tails (second half re the whole beat, dB) under this count as
        # silence.
        TAIL_FLOOR_DB = -60.0

        # Side re mid levels (dB) under this count as mono.
        STEREO_FLOOR_DB = -40.0

        # A band "missing" (or added) when it moves this many dB.
        MISSING_DB = 12.0

        # A lag counts when its waveform correlation reaches this.
        MIN_LAG_CORRELATION = 0.3

        # One compared bar: +bar+ (A's bar number; +b_bar+ B's), +deltas+ ({
        # measure => B minus A }; +bands+ as one delta per octave band and
        # +lag_*+ in ms), +lags+ ({ band => [lag ms, correlation] }),
        # +scores+ ({ measure => |delta| / threshold }), and +score+ (the
        # largest).
        Bar = Data.define(:bar, :b_bar, :deltas, :lags, :scores, :score) do
          # The measures that moved (score 1 or more), largest first.
          def moved = scores.select { |_, s| s >= 1 }.sort_by { |_, s| -s }.map(&:first)

          def to_s
            parts = moved.first(3).map { |m| "#{m} #{Comparison.delta_text(m, deltas[m])}" }
            "bar #{bar}#{b_bar == bar ? '' : " (B #{b_bar})"}: #{parts.empty? ? 'within thresholds' : parts.join(', ')}"
          end

          def inspect = "#<Comparison::Bar #{self}>"
        end

        # A likely cause: +kind+ (a CAUSES key), +bars+ (A's bar numbers),
        # +measure+, +value+ (the typical change), and +text+.
        Cause = Data.define(:kind, :measure, :value, :bars, :text) do
          def to_s = text
        end

        # One failing value: +bar+, +measure+, +delta+ (for +bands+ one per
        # octave band), +threshold+.
        Failure = Data.define(:bar, :measure, :delta, :threshold) do
          def to_s = "bar #{bar}: #{measure} #{Comparison.delta_text(measure, delta)} (threshold #{threshold})"
        end

        # The rules for likely causes and what each one suggests.
        CAUSES = {
          file_offset: 'every band offset alike: the files are offset (encoder delay or a trimmed start), not the mix',
          band_offset: 'a constant onset offset in one band: a late (or early) bus or track',
          tail: 'tail energy after hits changed: reverb or delay',
          over_compression: 'louder with less crest: over-compression or limiting',
          band_level: 'a band missing or added: EQ, or a missing part',
          chroma: 'different pitch classes: a wrong clip or a transpose',
          stereo: 'width or correlation changed: a mono fold or a missing wide part',
          level: 'a level change with the same crest: gain, automation, or a part missing',
        }.freeze

        attr_reader :a, :b, :bars, :thresholds, :labels

        # Compares +a+ and +b+ (files, audio data, or Reports); see
        # BarStats.compare.  +b+ is measured on +a+'s grid shifted by
        # +align+ seconds (B's audio later by that much).
        def self.of(a, b, align: 0, max_lag: MAX_LAG, thresholds: {}, labels: nil, **options)
          ra = a.is_a?(Report) ? a : BarStats.analyze(a, **options)
          rb = b.is_a?(Report) ? b : BarStats.analyze(b, **options.except(:bpm, :offset, :grid, :sections), grid: ra.grid.shift(align), sections: ra.grid.sections.map { |s| s.with(seconds: s.seconds + align, end_seconds: s.end_seconds + align) })
          audio_a = audio_of(a)
          audio_b = audio_of(b)
          lags = nil
          if audio_a && audio_b
            mb = shift(audio_b, (align * RATE).round)
            spans = ra.bars.keys.each_index.map { |i| [ra.bars[:seconds][i], ra.bars[:seconds][i] + ra.bars[:length][i]] }
            lags = Timing.lags(audio_a, mb, RATE, spans, max_lag: max_lag)
          end
          pairs = ra.bars.keys.each_index.filter_map { |i|
            n = ra.bars.keys[i]
            j = rb.bars.keys.index(n)
            j && [ra.bars.row(i), rb.bars.row(j), lags && Bands::NAMES.to_h { |band| [band, lags[band][i]] }]
          }
          new(ra, rb, pairs, thresholds: thresholds, labels: labels || [name_of(a, 'A'), name_of(b, 'B')], align: align)
        end

        # Compares two sections of one Report (bar by bar from each
        # section's first bar; timing from the onset offsets, without
        # lags).
        def self.sections(report, a_label, b_label, thresholds: {})
          sa = report.grid.sections.find { |s| s.label == a_label.to_s } || raise(ArgumentError, "No section #{a_label.inspect} (#{report.grid.sections.map(&:label).join(', ')})")
          sb = report.grid.sections.find { |s| s.label == b_label.to_s } || raise(ArgumentError, "No section #{b_label.inspect} (#{report.grid.sections.map(&:label).join(', ')})")
          pairs = [sa.bars, sb.bars].min.times.filter_map { |k|
            ra = report.bar(sa.first_bar + k)
            rb = report.bar(sb.first_bar + k)
            ra && rb && [ra, rb, nil]
          }
          new(report, report, pairs, thresholds: thresholds, labels: [a_label.to_s, b_label.to_s], align: 0)
        end

        # The mono audio of a source at RATE (nil for a Report without a
        # readable file).
        def self.audio_of(source)
          source = source.file if source.is_a?(Report)
          return nil if source.nil? || (source.is_a?(String) && !File.file?(source))
          channels, = BarStats.read(source, RATE)
          channels.length == 1 ? channels[0] : channels.sum / channels.length
        end

        # +x+ with +n+ samples dropped from its start (n > 0) or n zeros put
        # before it (n < 0), so B's audio lines up with A's.
        def self.shift(x, n)
          return x if n == 0
          return x[n..].dup if n > 0
          Numo::DFloat.zeros(-n).concatenate(x)
        end

        def self.name_of(source, fallback)
          source = source.file if source.is_a?(Report)
          source.is_a?(String) ? File.basename(source) : fallback
        end

        # A change as text: "+66.0 ms", "-1.2 dB", "+12%".
        def self.delta_text(measure, d)
          return 'n/a' if d.nil?
          if d.is_a?(Array)
            k = d.each_index.select { |i| d[i] }.max_by { |i| d[i].abs }
            return 'n/a' unless k
            return "#{hz(Analysis::Spectrum::OCTAVE_CENTERS[k])} #{format('%+.1f dB', d[k])}"
          end
          case GROUP[measure] || measure
          when :timing then format('%+.1f ms', d)
          when :centroid then format('%+.0f%%', d * 100)
          when :tilt then format('%+.2f dB/oct', d)
          when :correlation then format('%+.2f', d)
          when :chroma then format('%.2f', d)
          when :lufs then format('%+.1f LU', d)
          else format('%+.1f dB', d)
          end
        end

        # +a+ and +b+ the Reports, +pairs+ [A bar row, B bar row, lags or
        # nil] in A's order, +thresholds+ merged over THRESHOLDS.
        def initialize(a, b, pairs, thresholds: {}, labels: %w[A B], align: 0)
          @a = a
          @b = b
          @labels = labels
          @align = align
          @thresholds = THRESHOLDS.merge(thresholds).freeze
          @centers = Analysis::Spectrum::OCTAVE_CENTERS
          @bars = pairs.map { |ra, rb, lags| compare_bar(ra, rb, lags) }.freeze
          @causes = nil
        end

        # The compared bars, worst first (+n+ of them, or all).
        def worst(n = nil)
          list = @bars.sort_by { |b| [-b.score, b.bar] }
          n ? list.first(n) : list
        end

        # The failing values under +thresholds+ (merged over this
        # comparison's), in bar order.
        def failures(**thresholds)
          t = @thresholds.merge(thresholds)
          @bars.flat_map { |b|
            b.deltas.filter_map { |m, d|
              group = m == :bands ? :bands : GROUP.fetch(m)
              limit = t[group]
              next if limit.nil? || d.nil?
              value = m == :bands ? d.compact.map(&:abs).max : (m == :centroid ? d.abs : d.abs)
              Failure.new(bar: b.bar, measure: m, delta: d, threshold: limit) if value && value >= limit
            }
          }
        end

        # True if no value fails (see #failures).
        def pass?(**thresholds) = failures(**thresholds).empty?

        # Raises with the failing bars named unless #pass?.
        def check!(**thresholds)
          f = failures(**thresholds)
          return self if f.empty?
          by = f.group_by(&:measure).map { |m, list| "#{m} in bars #{Comparison.bar_list(list.map(&:bar).uniq)}" }
          raise RuntimeError, "#{@labels[1]} differs from #{@labels[0]}: #{by.join('; ')}\n#{f.first(10).map { |x| "  #{x}" }.join("\n")}"
        end

        # Bar numbers as ranges: "1-8, 12, 15-16".
        def self.bar_list(numbers)
          numbers.sort.slice_when { |x, y| y != x + 1 }.map { |r| r.length == 1 ? r[0].to_s : "#{r[0]}-#{r[-1]}" }.join(', ')
        end

        # The median lag in ms of each band over the bars (nil without
        # lags), and the number of bars that had one.
        def band_lags
          Bands::NAMES.to_h { |band|
            values = @bars.filter_map { |b| b.lags && b.lags[band] && b.lags[band][1] >= MIN_LAG_CORRELATION ? b.lags[band][0] : nil }
            [band, values.empty? ? nil : [Analysis::DSP.median(values).round(2), values.length]]
          }
        end

        # Likely causes (Cause values), by the rules in CAUSES.
        def causes
          @causes ||= find_causes.freeze
        end

        # A plain-text summary, as an agent would say it in chat.
        def narrative
          a, b = @labels
          n = @bars.length
          bad = @bars.count { |x| x.score >= 1 }
          out = []
          out << "#{b} against #{a}, #{n} bar#{n == 1 ? '' : 's'} compared#{@align != 0 ? format(' (B aligned %+.1f ms)', @align * 1000) : ''}: " +
                 (bad == 0 ? 'every bar is within the thresholds.' : "#{bad} bar#{bad == 1 ? '' : 's'} differ beyond the thresholds.")
          lags = band_lags.filter_map { |band, (lag, count)| lag && "#{band} #{format('%+.1f', lag)} ms" }
          out << "Band timing (median lag of #{b} behind #{a}): #{lags.join(', ')}." unless lags.empty?
          if bad > 0
            w = worst(3).select { |x| x.score >= 1 }
            out << "Worst: #{w.map(&:to_s).join('; ')}."
          end
          causes.each { |c| out << "Likely: #{c.text}." }
          moved = @bars.flat_map(&:moved).map { |m| GROUP[m] || m }.uniq
          steady = (%i[timing lufs bands chroma width] - moved)
          out << "Within thresholds throughout: #{steady.join(', ')}." if bad > 0 && !steady.empty?
          out.join("\n")
        end

        def to_s
          [narrative, *worst(10).select { |x| x.score >= 1 }.map { |x| "  #{x}" }].join("\n")
        end

        def inspect
          "#<BarStats::Comparison #{@labels.join(' vs ')}: #{@bars.length} bars, #{@bars.count { |x| x.score >= 1 }} over thresholds>"
        end

        private

        # The Bar for rows +ra+ and +rb+ with +lags+ ({ band => [lag samples,
        # correlation, onset lag] or nil }).
        def compare_bar(ra, rb, lags)
          d = {}
          lag_ms = {}
          if lags
            Bands::NAMES.each do |band|
              l = lags[band]
              next unless l
              lag_ms[band] = [(l[0] / RATE * 1000).round(2), l[1]]
              d[:"lag_#{band}"] = l[1] >= MIN_LAG_CORRELATION ? lag_ms[band][0] : nil
            end
          else
            Bands::NAMES.each { |band| d[:"onset_#{band}"] = diff(ra[:"onset_#{band}"], rb[:"onset_#{band}"]) }
          end
          %i[lufs rms true_peak crest tilt correlation].each { |m| d[m] = diff(ra[m], rb[m]) }
          # (silence after the hits reads as TAIL_FLOOR_DB)
          d[:tail] = diff(ra[:tail] && [ra[:tail], TAIL_FLOOR_DB].max, rb[:tail] && [rb[:tail], TAIL_FLOOR_DB].max)
          # (side levels under STEREO_FLOOR_DB read as it: mono is mono, and a
          # collapse to mono shows)
          %i[width side_low side_mid side_high].each { |m| d[m] = diff(floored(ra[m]), floored(rb[m])) }
          d[:centroid] = ra[:centroid] && rb[:centroid] && ra[:centroid] > 0 ? (rb[:centroid] / ra[:centroid] - 1).round(4) : nil
          if ra[:bands] && rb[:bands]
            d[:bands] = ra[:bands].zip(rb[:bands]).map { |x, y|
              x = [x || -Float::INFINITY, FLOOR_DB].max
              y = [y || -Float::INFINITY, FLOOR_DB].max
              x <= FLOOR_DB && y <= FLOOR_DB ? nil : (y - x).round(2)
            }
          end
          d[:chroma] = ra[:chroma] && rb[:chroma] ? (1 - cosine(ra[:chroma], rb[:chroma])).round(4) : nil
          d.compact!

          scores = d.filter_map { |m, v|
            group = m == :bands ? :bands : GROUP.fetch(m)
            limit = @thresholds[group]
            next if limit.nil? || limit == 0
            value = m == :bands ? (v.compact.map(&:abs).max || 0) : v.abs
            [m, (value / limit).round(3)]
          }.to_h
          Bar.new(bar: ra[:bar], b_bar: rb[:bar], deltas: d.freeze, lags: lags ? lag_ms.freeze : nil, scores: scores.freeze, score: scores.values.max || 0.0)
        end

        # +v+ at STEREO_FLOOR_DB or above (nil stays nil).
        def floored(v) = v && [v, STEREO_FLOOR_DB].max

        def diff(x, y)
          return nil if x.nil? || y.nil?
          return nil unless x.finite? && y.finite?
          (y - x).round(3)
        end

        def cosine(a, b)
          na = Math.sqrt(a.sum { |v| v * v })
          nb = Math.sqrt(b.sum { |v| v * v })
          na > 0 && nb > 0 ? a.zip(b).sum { |x, y| x * y } / (na * nb) : 0.0
        end

        # The bar numbers where +block+ holds.
        def where(&block) = @bars.select(&block).map(&:bar)

        # Enough bars for a constant offset: at least 2 and a quarter of the
        # bars, or every bar of a short comparison.  (Localized causes need
        # one bar: finding those is what bar statistics are for.)
        def enough?(count) = count >= [[2, (@bars.length * 0.25).ceil].max, @bars.length].min

        def find_causes
          out = []
          t = @thresholds
          a, b = @labels

          # Timing per band
          if t[:timing]
            lags = band_lags
            known = lags.select { |_, v| v }
            if known.length == Bands::NAMES.length && known.values.map(&:first).minmax.then { |lo, hi| hi - lo } < 1.0 && known.values.first[0].abs >= t[:timing]
              lag = (known.values.sum { |v| v[0] } / known.length).round(1)
              out << Cause.new(kind: :file_offset, measure: :timing, value: lag, bars: @bars.map(&:bar),
                               text: "every band of #{b} is #{lag.abs} ms #{lag > 0 ? 'late' : 'early'} (#{CAUSES[:file_offset]}; align: #{format('%.4f', lag / 1000.0)})")
            else
              known.each do |band, (lag, count)|
                next if lag.abs < t[:timing]
                key = :"lag_#{band}"
                agree = where { |x| (v = x.deltas[key]) && (v - lag).abs <= [1.0, t[:timing] * 0.25].max }
                next unless enough?(agree.length)
                others = known.reject { |k, _| k == band }.select { |_, (l, _)| l.abs < t[:timing] }.keys
                with = others.empty? ? '' : " while #{others.join(' and ')} #{others.length == 1 ? 'stays' : 'stay'} on time"
                out << Cause.new(kind: :band_offset, measure: key, value: lag, bars: agree,
                                 text: "the #{band} band of #{b} is #{lag.abs} ms #{lag > 0 ? 'late' : 'early'} in #{agree.length} of #{@bars.length} bars (#{Comparison.bar_list(agree)})#{with}: #{CAUSES[:band_offset]}")
              end
              # Without audio: onset offsets from the grid
              Bands::NAMES.each do |band|
                key = :"onset_#{band}"
                values = @bars.filter_map { |x| x.deltas[key] }
                next if values.length < 2
                med = Analysis::DSP.median(values)
                next if med.abs < t[:timing]
                agree = where { |x| (v = x.deltas[key]) && (v - med).abs <= [1.0, t[:timing] * 0.25].max }
                next unless enough?(agree.length)
                out << Cause.new(kind: :band_offset, measure: key, value: med.round(1), bars: agree,
                                 text: "#{band}-band onsets of #{b} land #{med.abs.round(1)} ms #{med > 0 ? 'later' : 'earlier'} against the grid in #{agree.length} bars (#{Comparison.bar_list(agree)}): #{CAUSES[:band_offset]}")
              end
            end
          end

          # Tails
          if t[:tail]
            short = where { |x| (v = x.deltas[:tail]) && v <= -t[:tail] }
            long = where { |x| (v = x.deltas[:tail]) && v >= t[:tail] }
            [[short, 'shorter', -1], [long, 'longer', 1]].each do |list, word, sign|
              next if list.empty?
              med = Analysis::DSP.median(list.map { |n| @bars.find { |x| x.bar == n }.deltas[:tail] })
              out << Cause.new(kind: :tail, measure: :tail, value: med.round(1), bars: list,
                               text: "tails after hits are #{word} in #{b} (#{format('%+.1f', med)} dB, bars #{Comparison.bar_list(list)}): #{CAUSES[:tail]}#{sign < 0 ? ' missing or shorter' : ' added or longer'}")
            end
          end

          # Over-compression
          if t[:lufs] && t[:crest]
            list = where { |x| (l = x.deltas[:lufs]) && (c = x.deltas[:crest]) && l >= t[:lufs] && c <= -t[:crest] }
            unless list.empty?
              out << Cause.new(kind: :over_compression, measure: :crest, value: nil, bars: list,
                               text: "#{b} is louder with less crest in bars #{Comparison.bar_list(list)}: #{CAUSES[:over_compression]}")
            end
          end

          # Bands missing or added (neighboring octaves moving in the same
          # bars make one cause)
          if t[:bands]
            [[-1, 'down', 'missing'], [1, 'up', 'added']].each do |sign, dir, what|
              moved = @centers.each_index.map { |k| where { |x| (v = x.deltas[:bands]&.at(k)) && v * sign >= MISSING_DB } }
              groups = []
              moved.each_with_index do |list, k|
                next if list.empty?
                if groups.last && groups.last[:last] == k - 1 && (groups.last[:bars] & list).length * 2 >= [list.length, groups.last[:bars].length].min
                  groups.last[:last] = k
                  groups.last[:bars] |= list
                else
                  groups << { first: k, last: k, bars: list }
                end
              end
              groups.each do |g|
                values = (g[:first]..g[:last]).flat_map { |k| moved[k].map { |n| @bars.find { |x| x.bar == n }.deltas[:bands][k].abs } }
                lo, hi = values.minmax
                span = g[:first] == g[:last] ? "the #{Comparison.hz(@centers[g[:first]])} octave" : "the #{Comparison.hz(@centers[g[:first]])} to #{Comparison.hz(@centers[g[:last]])} octaves"
                amount = (hi - lo) < 3 ? "#{Analysis::DSP.median(values).round(1)} dB" : "#{lo.round(0).to_i}-#{hi.round(0).to_i} dB"
                bars = g[:bars].sort
                out << Cause.new(kind: :band_level, measure: :bands, value: (sign * Analysis::DSP.median(values)).round(1), bars: bars,
                                 text: "#{span} of #{b} #{g[:first] == g[:last] ? 'is' : 'are'} #{amount} #{dir} (#{what}) in bars #{Comparison.bar_list(bars)}: #{CAUSES[:band_level]}")
              end
            end
          end

          # Harmony
          if t[:chroma]
            list = where { |x| (v = x.deltas[:chroma]) && v >= t[:chroma] }
            unless list.empty?
              shifts = list.filter_map { |n| transpose_of(n) }
              common = shifts.tally.max_by(&:last)
              text =
                if common && common[1] * 2 >= list.length && common[0] != 0
                  "#{b}'s pitch classes are #{common[0] > 0 ? '+' : ''}#{common[0]} semitones from #{a}'s in bars #{Comparison.bar_list(list)}: a transpose"
                else
                  "#{b} plays other pitch classes in bars #{Comparison.bar_list(list)}: #{CAUSES[:chroma]}"
                end
              out << Cause.new(kind: :chroma, measure: :chroma, value: common&.first, bars: list, text: text)
            end
          end

          # Stereo
          if t[:width] || t[:correlation]
            list = where { |x| (t[:width] && (w = x.deltas[:width]) && w <= -t[:width]) || (t[:correlation] && (c = x.deltas[:correlation]) && c >= t[:correlation]) }
            unless list.empty?
              out << Cause.new(kind: :stereo, measure: :width, value: nil, bars: list,
                               text: "#{b} is narrower (closer to mono) in bars #{Comparison.bar_list(list)}: #{CAUSES[:stereo]}")
            end
          end

          # Level steps with the same crest
          if t[:lufs]
            [[:down, ->(v) { v <= -t[:lufs] }], [:up, ->(v) { v >= t[:lufs] }]].each do |dir, test|
              list = where { |x| (l = x.deltas[:lufs]) && test.(l) && (x.deltas[:crest].nil? || x.deltas[:crest].abs < (t[:crest] || Float::INFINITY)) }
              next if list.empty?
              med = Analysis::DSP.median(list.map { |n| @bars.find { |x| x.bar == n }.deltas[:lufs] })
              out << Cause.new(kind: :level, measure: :lufs, value: med.round(1), bars: list,
                               text: "#{b} is #{med.abs.round(1)} LU #{dir == :down ? 'quieter' : 'louder'} in bars #{Comparison.bar_list(list)} with the same crest: #{CAUSES[:level]}")
            end
          end
          out
        end

        # The rotation (semitones, -5..6) of A's chroma that best matches
        # B's in bar +n+, if it explains the change.
        def transpose_of(n)
          ra = @a.bar(n)
          rb = @b.bar(n)
          return nil unless ra && rb && ra[:chroma] && rb[:chroma]
          best = (-5..6).max_by { |k| cosine(ra[:chroma].rotate(-k), rb[:chroma]) }
          1 - cosine(ra[:chroma].rotate(-best), rb[:chroma]) < @thresholds[:chroma] / 2 ? best : nil
        end

        public

        # "63 Hz", "1 kHz", "16 kHz".
        def self.hz(f) = f >= 1000 ? "#{(f / 1000.0).to_s.delete_suffix('.0')} kHz" : "#{f.to_s.delete_suffix('.0')} Hz"
      end
    end
  end
end
