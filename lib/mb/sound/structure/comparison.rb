module MB
  module Sound
    module Structure
      # Analyzed sections against the form that played (phase S2's
      # self-check: a render's flow, `take.form`, or a list of [name, bars]):
      # section boundaries matched one to one within +tolerance+ bars
      # (precision, recall, F), and the labels compared pairwise (for every
      # pair of bars both cover: the same section name in the form against
      # the same letter in the analysis, primes ignored; precision, recall,
      # F of "same").  The research spike's scoring, as a value to print or
      # assert on.
      #
      #     c = analyze_form(bars: 40) { song }.compare(take.form)
      #     c.f          # => 1.0
      #     c.missed     # => [] (expected boundaries no section starts near)
      #     puts c       # the two lists side by side
      Comparison = Data.define(:expected, :found, :matched, :missed, :extra, :precision, :recall, :f, :label_precision, :label_recall, :label_f, :tolerance) do
        # +expected+: [[name, first bar, bars], ...]; +found+: the
        # Structure::Section list; +matched+: [[expected bar, found bar],
        # ...]; +missed+/+extra+: boundary bars of +expected+ and +found+
        # nothing matched.

        # Builds the Comparison of +result+'s sections with +form+ (a Form
        # or [[name, bars], ...]) starting at bar +from+.
        def self.of(result, form, from: 1, tolerance: 1)
          bar_length = Rational(result.beats_per_bar, 4)
          list = form.is_a?(Form) ? Comparison.passes(form, bar_length) : form.map { |n, b| [n.to_sym, b] }
          expected = []
          at = from
          list.each do |name, bars|
            expected << [name, at, bars]
            at += bars
          end
          found = result.sections
          first = result.bars.first&.number || from
          last = result.bars.last ? result.bars.last.number + 1 : from
          # Boundaries are section starts after the first, inside the
          # analyzed bars (silent ends are trimmed from the analysis)
          eb = expected.map { |_, b, _| b }.select { |b| b > first && b < last }
          fb = found.map(&:first_bar).select { |b| b > first }

          pairs = eb.product(fb).map { |e, f| [(e - f).abs, e, f] }.select { |d, _, _| d <= tolerance }.sort
          used_e = {}
          used_f = {}
          matched = []
          pairs.each do |_, e, f|
            next if used_e[e] || used_f[f]
            used_e[e] = used_f[f] = true
            matched << [e, f]
          end
          matched.sort!
          precision = fb.empty? ? (eb.empty? ? 1.0 : 0.0) : matched.length.to_f / fb.length
          recall = eb.empty? ? 1.0 : matched.length.to_f / eb.length
          f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0.0

          lp, lr, lf = Comparison.label_scores(expected, found)
          new(expected: expected.freeze, found: found, matched: matched.freeze, missed: (eb - used_e.keys).freeze,
            extra: (fb - used_f.keys).freeze, precision: precision.round(4), recall: recall.round(4), f: f.round(4),
            label_precision: lp, label_recall: lr, label_f: lf, tolerance: tolerance)
        end

        # [[name, bars], ...] for each pass of +form+'s plays (repeats
        # unrolled; Durations in bars of +bar_length+ whole notes).
        def self.passes(form, bar_length)
          form.plays.flat_map { |name, times, len|
            bars = len.is_a?(Sequence::Duration) ? len.to_r / bar_length : len.to_r
            bars = bars.denominator == 1 ? bars.to_i : bars
            [[name, bars]] * times
          }
        end

        # Pairwise label [precision, recall, F] of "same section" for the
        # bars both lists cover.
        def self.label_scores(expected, found)
          truth = {}
          expected.each { |name, b, n| n.to_i.times { |i| truth[b + i] = name } }
          guess = {}
          found.each { |s| s.bars.times { |i| guess[s.first_bar + i] = s.letter } }
          bars = (truth.keys & guess.keys).sort
          both = t_same = g_same = 0
          bars.each_with_index do |a, i|
            bars[(i + 1)..].each do |b|
              t = truth[a] == truth[b]
              g = guess[a] == guess[b]
              t_same += 1 if t
              g_same += 1 if g
              both += 1 if t && g
            end
          end
          p = g_same > 0 ? both.to_f / g_same : 1.0
          r = t_same > 0 ? both.to_f / t_same : 1.0
          [p.round(4), r.round(4), (p + r > 0 ? 2 * p * r / (p + r) : 0.0).round(4)]
        end

        # True if every boundary matched and none was extra.
        def exact?
          missed.empty? && extra.empty?
        end

        def to_s
          rows = (expected.map { |_, b, _| b } | found.map(&:first_bar)).sort
          names = expected.to_h { |n, b, _| [b, n.to_s] }
          labels = found.to_h { |s| [s.first_bar, s.label] }
          w = [8, *names.values.map(&:length)].max
          lines = [
            format('boundaries: %d of %d found within %d bar%s (P %.2f, R %.2f, F %.2f); labels F %.2f (P %.2f, R %.2f)',
              matched.length, matched.length + missed.length, tolerance, tolerance == 1 ? '' : 's', precision, recall, f, label_f, label_precision, label_recall),
            format("  %5s  %-#{w}s  %s", 'bar', 'expected', 'found'),
          ]
          rows.each { |b| lines << format("  %5d  %-#{w}s  %s", b, names[b] || '', labels[b] || '').rstrip }
          lines << "  missed: #{missed.map { |b| "bar #{b}" }.join(', ')}" unless missed.empty?
          lines << "  extra: #{extra.map { |b| "bar #{b}" }.join(', ')}" unless extra.empty?
          lines.join("\n")
        end

        def inspect
          "#<Structure::Comparison #{to_s.lines.first.chomp}>"
        end
      end
    end
  end
end
