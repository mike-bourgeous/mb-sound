module MB
  module Sound
    class Sample
      # The slice stretch (Sample#stretch with mode: :slice), the way
      # ACID, REX files, and beat-slicing samplers stretch drum loops: cut
      # the loop at its hits and start each slice at its stretched time,
      # copied sample for sample, so every attack stays exactly as it was
      # and lands where the new tempo puts it.
      #
      # Slowing down (+ratio+ > 1) leaves a gap after each slice: with
      # +fill+ :gap (default) the slice plays its own audio and fades out
      # over +fade+ before its end (where the next hit was), then silence
      # until its next hit (the classic REX sound: tight, a little gated);
      # with :stretch the slice keeps its first +attack+ samples and its
      # decay is drawn out to the next hit by the cyclic stretch (Lofi,
      # fitted cycles), so it rings on.  Speeding up (+ratio+ < 1)
      # truncates each slice, fading out over +fade+ before the next one's
      # new time.  Every slice that doesn't follow on from the one before
      # (as it did in the input) fades in its input's last +fade+ samples
      # before its start (a pre-roll, crossfading with the fade-out), so the
      # attack itself is copied exactly and joins what led into it in the
      # input instead of stepping out of silence.  The first slice gets its
      # pre-roll from the loop's end, at the output's end, so loops that
      # were seamless stay seamless.  Where a slice runs straight into the
      # next as in the input (ratio 1) nothing is faded: the output is the
      # input.
      #
      # Pure Ruby + Numo (per slice copies; fill: :stretch runs Lofi.stretch
      # per slice).  Every channel cuts in the same places.
      module SliceStretch
        # The default fade at a slice's end (seconds).
        FADE = 0.004

        # With fill: :stretch, the part of each slice kept exactly before
        # its decay is stretched (seconds).
        ATTACK = 0.015

        FILLS = [:gap, :stretch].freeze

        module_function

        # +channels+ (DFloat or SFloat arrays in play order) stretched by
        # +ratio+, cut at +cuts+ (sample positions, 0 first; the end is
        # added).  +fade+ in samples; +attack+, +cycle+, and +crossfade+
        # (the fill's stretch) in samples.  Returns Arrays of SFloat.
        def stretch(channels, ratio, cuts, fade:, fill: :gap, attack: 720, cycle: 1200, crossfade: 144, sample_rate: 48000)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio.is_a?(Numeric) && ratio > 0
          raise ArgumentError, "fill: is one of #{FILLS.inspect} (got #{fill.inspect})" unless FILLS.include?(fill)

          x = channels.map { |c| Numo::DFloat.cast(c) }
          len = x[0].length
          n_out = (len * ratio).round
          p = (cuts.map { |c| Integer(c) }.select { |c| c > 0 && c < len } + [0, len]).uniq.sort
          q = p.map { |c| (c * ratio).round }
          q[-1] = n_out

          out = x.map { Numo::DFloat.zeros(n_out) }
          guide = fill == :stretch ? x.sum / x.length : nil
          joined = [] # whether slice i follows on from slice i - 1

          (p.length - 1).times do |i|
            a, b = p[i], p[i + 1]
            qa = q[i]
            slot = q[i + 1] - qa
            own = b - a
            next if slot <= 0

            segs =
              if fill == :stretch && slot > own && own - attack >= 2 * cycle
                fill_slice(x, guide, a, b, slot, attack, cycle, crossfade, sample_rate)
              else
                m = MB::M.min(slot, own)
                x.map { |c| c[a...(a + m)].dup }
              end
            m = segs[0].length
            continuous = m == own && slot == own
            joined[i + 1] = continuous

            fo = continuous ? 0 : MB::M.min(fade, m / 2)
            segs.each_with_index do |seg, ch|
              seg[(m - fo)...m] *= ramp(fo, false) if fo > 0
              out[ch][qa...(qa + m)] += seg
            end
          end

          # Pre-rolls into slices that don't follow on from the one before
          # (the first slice's from the loop's end, at the output's end)
          (p.length - 1).times do |i|
            next if joined[i]
            if i == 0
              next if joined[p.length - 1] || n_out < 2
              f = [fade, len / 2, n_out / 2].min
              x.each_with_index { |c, ch| out[ch][(n_out - f)...n_out] += c[(len - f)...len] * ramp(f, true) } if f > 0
            else
              f = [fade, p[i], q[i]].min
              x.each_with_index { |c, ch| out[ch][(q[i] - f)...q[i]] += c[(p[i] - f)...p[i]] * ramp(f, true) } if f > 0
            end
          end

          out.map { |o| Numo::SFloat.cast(o) }
        end

        # A slice from +a+ to +b+ filled out to +slot+ samples: the first
        # +attack+ samples as they are, the rest cyclic-stretched.
        def fill_slice(x, guide, a, b, slot, attack, cycle, crossfade, sample_rate)
          rest = b - (a + attack)
          r = (slot - attack).to_f / rest
          g = guide[(a + attack)...b]
          x.map { |c|
            tail = Lofi.stretch(c[(a + attack)...b], r, cycle, crossfade, fit: :auto, guide: g, sample_rate: sample_rate)
            seg = Numo::DFloat.zeros(slot)
            seg[0...attack] = c[a...(a + attack)]
            k = MB::M.min(tail.length, slot - attack)
            seg[attack...(attack + k)] = Numo::DFloat.cast(tail[0...k])
            seg
          }
        end

        # A raised-cosine fade of +n+ samples (in or out).
        def ramp(n, rising)
          t = (Numo::DFloat.new(n).seq + 0.5) / n
          w = 0.5 - 0.5 * Numo::NMath.cos(t * Math::PI)
          rising ? w : w.reverse
        end
      end
    end
  end
end
