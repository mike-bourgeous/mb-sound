module MB
  module Sound
    module Structure
      # One section found by the analysis (phase S2): its +label+ (a letter,
      # with primes for variants: "A", "B", "A'"), its flow +name+ (:a, :b,
      # :a2), its +first_bar+ (a bar number, as Structure::Bar#number), its
      # length in +bars+, its start and end in +seconds+ / +end_seconds+,
      # and its length in quarter-note +beats+.
      Section = Data.define(:label, :name, :first_bar, :bars, :seconds, :end_seconds, :beats) do
        # The bar numbers the section covers.
        def bar_range
          first_bar...(first_bar + bars)
        end

        # The label's letter without primes ("A" for "A'").
        def letter
          label.delete("'")
        end

        def to_s
          format('%-4s bar %d, %d bar%s at %s', label, first_bar, bars, bars == 1 ? '' : 's', Structure.clock(seconds))
        end

        def inspect
          "#<Section #{self}>"
        end
      end

      # Sections from bar features (phase S2; the research spike's method,
      # research-structure-analysis): per bar, timbre (mean MFCC 1..13 and
      # energy), harmony (mean chroma over its peak), and rhythm (a 16-step
      # onset pattern in the three onset bands), each group standardized
      # over the song (with a floor on each spread) and weighted equally; a
      # regularized cosine self-similarity matrix (SSM) of the bars; Foote
      # checkerboard novelty with a Gaussian taper at half widths of 2, 4,
      # and 8 bars (each counting only where its kernel fits); boundaries on bar lines by dynamic programming (the
      # novelty at each boundary, minus +cost+ per boundary, plus a prior on
      # section lengths favoring 8 and 16 bars (the last section's length
      # free: songs end in tails of any length), plus a bonus at irregular
      # bars); labels by the cosine of each section's mean features against
      # the first section of each earlier label (same at +same+, a variant
      # at +variant+, else a new letter).
      module Sections
        # The section length prior (bars => score; others OTHER_LENGTH).
        LENGTH_PRIOR = { 8 => 0.0, 16 => 0.0, 4 => -0.05, 32 => -0.05, 12 => -0.1, 24 => -0.1, 2 => -0.15, 1 => -0.2 }.freeze
        OTHER_LENGTH = -0.25

        # Novelty kernel half widths (bars).
        SCALES = [2, 4, 8].freeze

        # Defaults: the cost of a boundary, the bonus at an irregular bar's
        # edges, the longest section (bars; but the last), and the label
        # similarities.
        COST = 0.1
        METER_BONUS = 0.1
        MAX_LENGTH = 32
        SAME = 0.8
        VARIANT = 0.5

        # Feature groups (columns of .features' rows).
        GROUPS = %i[timbre harmony rhythm].freeze

        # The smallest spread (standard deviation over the bars) a feature
        # column is scaled by, per group (MFCC dB-ish units, shares of the
        # chroma peak, log flux), and the regularizer of the SSM's cosine
        # (in those scaled units): bars that differ only by noise (a loop
        # repeating with random hats) stay alike instead of being blown up
        # to unit variance.  listen-1 (2026-10-30): without them an 8-bar
        # loop of noise hats got 3 boundaries (novelty up to 0.32, over the
        # 0.1 cost; with them 0.08) and the night bus grid run F 0.82 with
        # 3 extra boundaries in the build and the outro; with them F 0.89.
        SCALE_FLOORS = [1.0, 0.1, 0.3].freeze
        SSM_EPSILON = 1.0

        module_function

        # Sections of the bars of +result+ (a Structure::Result): an Array
        # of Section.  Options as in the module description: +cost+,
        # +prior+, +other+, +meter_bonus+, +max_length+, +scales+, +same+,
        # +variant+.  Returns [sections, details] where details has
        # :features, :ssm, :novelty (per bar line, index 0 = the first
        # bar's downbeat), and :boundaries (bar indices).
        def find(result, cost: COST, prior: LENGTH_PRIOR, other: OTHER_LENGTH, meter_bonus: METER_BONUS,
          max_length: MAX_LENGTH, scales: SCALES, same: SAME, variant: VARIANT)
          bars = result.bars
          return [[], { features: nil, ssm: nil, novelty: nil, boundaries: [] }] if bars.empty?

          feat = features(result.frames, bars)
          s = ssm(feat)
          nov = novelty(s, scales: scales)
          usual = result.beats_per_bar
          irregular = bars.each_index.select { |i| i < bars.length - 1 && bars[i].beats != usual }
          bounds = segment(nov, bars.length, irregular, cost: cost, prior: prior, other: other, meter_bonus: meter_bonus, max_length: max_length)
          edges = [0, *bounds, bars.length]
          spans = edges.each_cons(2).to_a
          labels = label(feat, spans, same: same, variant: variant)
          sections = spans.zip(labels).map { |(a, b), l|
            Section.new(label: l, name: name_of(l), first_bar: bars[a].number, bars: b - a, seconds: bars[a].seconds,
              end_seconds: bars[b - 1].end_seconds, beats: bars[a...b].sum(&:beats))
          }
          [sections, { features: feat, ssm: s, novelty: nov, boundaries: bounds }]
        end

        # A flow section name for a label: "A" => :a, "A'" => :a2, "A''" => :a3.
        def name_of(label)
          primes = label.count("'")
          :"#{label.delete("'").downcase}#{primes > 0 ? primes + 1 : ''}"
        end

        # Bar features (bars x columns, Numo::DFloat): timbre (MFCC 1..13 +
        # energy), harmony (12 chroma over their peak), rhythm (16 steps x 3
        # onset bands, log(1 + the band flux peak near each step)); each
        # column centered on its mean over the bars and divided by its
        # spread (at least the group's SCALE_FLOORS entry), each group
        # scaled by 1 / sqrt of its width so the groups weigh the same.
        def features(frames, bars)
          fps = frames.fps
          count = frames.count
          rows = bars.map { |b|
            lo = (b.seconds * fps).round.clamp(0, count - 1)
            hi = (b.end_seconds * fps).round.clamp(lo + 1, count)
            timbre = frames.mfcc[lo...hi, 1..13].mean(axis: 0).to_a + [frames.energy[lo...hi].mean]
            ch = frames.chroma[lo...hi, true].mean(axis: 0)
            harmony = (ch / (ch.max + 1e-12)).to_a
            rhythm = frames.band_flux.flat_map { |band|
              16.times.map { |j|
                c = ((b.seconds + (b.end_seconds - b.seconds) * j / 16.0) * fps).round
                l2 = (c - 1).clamp(0, count - 1)
                h2 = (c + 2).clamp(l2 + 1, count)
                Math.log(1 + band[l2...h2].max)
              }
            }
            [timbre, harmony, rhythm]
          }
          groups = GROUPS.each_index.map { |g|
            m = Numo::DFloat.cast(rows.map { |r| r[g] })
            sd = m.stddev(axis: 0).clip(SCALE_FLOORS[g], nil)
            (m - m.mean(axis: 0)) / sd / Math.sqrt(m.shape[1])
          }
          Numo::DFloat.hstack(groups)
        end

        # The cosine self-similarity of feature rows, mapped to 0..1, each
        # row's norm regularized by SSM_EPSILON (rows near the song's mean
        # come out near 0.5 with every other row, not +-1 at random).
        def ssm(feat)
          norms = Numo::NMath.sqrt((feat**2).sum(axis: 1) + SSM_EPSILON**2)
          u = feat / norms.expand_dims(1)
          (u.dot(u.transpose) + 1) / 2
        end

        # Foote's checkerboard novelty of +s+ (n x n) with a Gaussian taper,
        # half width +half+ bars: n + 1 values, one per bar line (value i
        # measures a change between bar i - 1 and bar i), 0 where the kernel
        # doesn't fit (renormalizing a partial kernel made strong false
        # boundaries a bar or two from the start in the spike).
        def foote(s, half)
          n = s.shape[0]
          sig = half / 2.0
          kernel = []
          (-half...half).each { |u|
            (-half...half).each { |v|
              g = Math.exp(-((u + 0.5)**2 + (v + 0.5)**2) / (2 * sig * sig))
              kernel << [u, v, ((u < 0) == (v < 0) ? 1 : -1) * g]
            }
          }
          wpos = kernel.sum { |_, _, w| w > 0 ? w : 0 }
          wneg = -kernel.sum { |_, _, w| w < 0 ? w : 0 }
          norm = [wpos, wneg].min
          sa = s.to_a
          Numo::DFloat.cast((0..n).map { |i|
            next 0.0 if i - half < 0 || i + half > n
            kernel.sum { |u, v, w| w * sa[i + u][i + v] } / norm
          })
        end

        # Multi-scale novelty: the scales' curves (negative parts clipped)
        # summed and divided by how many fit at each bar line, so near the
        # ends the smaller scales alone count fully.  Absolute values (no
        # per-song normalization), so one +cost+ works across songs and a
        # song without changes gets no boundaries.
        def novelty(s, scales: SCALES)
          n = s.shape[0]
          curves = scales.map { |h| foote(s, h).clip(0, nil) }
          fits = Numo::DFloat.cast((0..n).map { |i| scales.count { |h| i - h >= 0 && i + h <= n } })
          curves.sum / fits.clip(1, nil)
        end

        # Boundaries (bar indices 1...n) by dynamic programming over bar
        # lines; see the module description.  +irregular+ lists the
        # irregular bars' indices.
        def segment(nov, n, irregular, cost:, prior:, other:, meter_bonus:, max_length:)
          na = nov.to_a
          bonus = Array.new(n + 1, 0.0)
          irregular.each { |i| bonus[i] += meter_bonus; bonus[i + 1] += meter_bonus if i + 1 < n }
          best = Array.new(n + 1, -Float::INFINITY)
          back = Array.new(n + 1, 0)
          best[0] = 0.0
          (1..n).each do |j|
            # (the last section may be any length; see the prior below)
            ((j == n ? 0 : [j - max_length, 0].max)...j).each do |i|
              # (the last section's length isn't judged: songs end in
              # tails, fades, and ring-outs of any length)
              v = best[i] + (j == n ? 0.0 : prior.fetch(j - i, other))
              v += na[j].to_f + bonus[j] - cost if j < n
              if v > best[j]
                best[j] = v
                back[j] = i
              end
            end
          end
          out = []
          j = back[n]
          while j > 0
            out << j
            j = back[j]
          end
          out.reverse
        end

        # Labels for +spans+ ([first, last + 1] bar indices) in order; see
        # the module description.  A span like an earlier label's first
        # span (cosine >= +same+) takes that label (variants included, so a
        # second variant is A' again, not A''); one like a letter's first
        # span (>= +variant+) becomes a new variant of that letter; others
        # take the next letter.
        def label(feat, spans, same:, variant:)
          means = spans.map { |a, b| feat[a...b, true].mean(axis: 0) }
          cos = ->(x, y) { (x * y).sum / (Math.sqrt((x * x).sum * (y * y).sum) + 1e-12) }
          reps = {}
          bases = {}
          primes = Hash.new(0)
          letters = ('A'..'Z').to_a + ('A'..'Z').flat_map { |a| ('A'..'Z').map { |b| a + b } }
          means.map { |m|
            label, sim = reps.map { |l, r| [l, cos.(m, r)] }.max_by(&:last)
            next label if label && sim >= same
            base, bsim = bases.map { |l, r| [l, cos.(m, r)] }.max_by(&:last)
            if base && bsim >= variant
              primes[base] += 1
              l = base + "'" * primes[base]
            else
              l = letters[bases.size]
              bases[l] = m
            end
            reps[l] = m
            l
          }
        end
      end
    end
  end
end
