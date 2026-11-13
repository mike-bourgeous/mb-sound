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
      # with :stretch the slice keeps its hit (its first +attack+ samples
      # exactly, and its length for as long as it is loud) and what it has
      # died down to is drawn out to the next hit (#fill_slice: a cyclic
      # stretch that follows the decay's level), so it rings on; :cyclic
      # is the plain cyclic stretch of everything after the attack (what
      # :stretch was before stretch-fixes-1, kept for comparing: it plays
      # parts of a hit's body twice).  Speeding up (+ratio+ < 1)
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
      # Pure Ruby + Numo (per slice copies; the fills plan and play a
      # cyclic stretch per slice).  Every channel cuts in the same places.
      module SliceStretch
        # The default fade at a slice's end (seconds).
        FADE = 0.004

        # With fill: :stretch, the part of each slice kept exactly before
        # its decay is stretched (seconds).
        ATTACK = 0.015

        # +fill+ values: :gap (silence after each slice), :stretch (each
        # decay drawn out: an anchored cyclic stretch whose level follows
        # the decay's stretched envelope), and :cyclic (the plain fitted
        # cyclic stretch of each decay, as :stretch was before
        # stretch-fixes-1: kept for comparing the two).
        FILLS = [:gap, :stretch, :cyclic].freeze

        # How far the :stretch fill turns a cycle down or up to keep the
        # level on the decay's stretched envelope.
        FILL_GAIN = (-36.db)..(6.db)

        # The smoothing (seconds) of the envelope the :stretch fill
        # follows (two moving averages of this length over the squared
        # magnitude of the analytic signal).
        FILL_SMOOTH = 0.01

        # Where the :stretch fill puts the stretch (levels against the
        # slice's loudest): none of it where the sound is within FILL_HOLD
        # of the loudest (a hit's body), all it can where the sound has
        # fallen by FILL_DECAY or more, in proportion in between (in dB),
        # plus FILL_EVEN of the full share everywhere, so a sound that
        # never dies down (a held note) is drawn out evenly.
        FILL_HOLD = -6.db
        FILL_DECAY = -20.db
        FILL_EVEN = 0.02

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
          guide = fill == :gap ? nil : x.sum / x.length
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
              elsif fill == :cyclic && slot > own && own - attack >= 2 * cycle
                cyclic_fill_slice(x, guide, a, b, slot, attack, cycle, crossfade, sample_rate)
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

        # A slice from +a+ to +b+ filled out to +slot+ samples (fill:
        # :stretch): the first +attack+ samples as they are, then the rest
        # drawn out where it has died down (#fill_map: a hit's body, and
        # any further hit in the slice, keeps its length, and the quiet
        # after it takes the stretch; a held sound is drawn out evenly),
        # by a cyclic stretch anchored at both ends (Lofi.anchored_plan:
        # it follows on from the attack and ends where the slice ends,
        # with no cycle forced far back), every cycle's level set to the
        # slice's own envelope (#envelope of +guide+, the channels' mix)
        # read at the stretched time.  A cycle that repeats an earlier,
        # louder part is turned down to where the decay has got to, so
        # nothing sounds like a second hit.  (The plain cyclic fill,
        # #cyclic_fill_slice, stretched everything after the attack
        # evenly: a kick's body played at its old time and then again, in
        # part, at its stretched time.)
        def fill_slice(x, guide, a, b, slot, attack, cycle, crossfade, sample_rate)
          need = slot - attack
          lead = MB::M.min(a, (4 * FILL_SMOOTH * sample_rate).round)
          env = envelope(guide[(a - lead)...b], (FILL_SMOOTH * sample_rate).round)
          base = lead + attack
          map = fill_map(env[base..], env[lead..].max, need)
          floor = env.max * 1e-4 + 1e-12
          low = FILL_GAIN.begin.to_f
          high = FILL_GAIN.end.to_f
          gain = ->(o, src, len) {
            t = map[o...(o + len)] + base
            i = Numo::Int64.cast(t.floor).clip(0, env.length - 2)
            f = (t - i).clip(0, 1)
            target = env[i] * (1 - f) + env[i + 1] * f
            ((target + floor) / (env[(base + src)...(base + src + len)] + floor)).clip(low, high)
          }
          plan = Lofi.anchored_plan(guide[(a + attack)...b], need, cycle, sample_rate: sample_rate, map: map)
          x.map { |c|
            tail = Lofi.play_plan(c[(a + attack)...b], plan, need, crossfade, gain: gain)
            seg = Numo::DFloat.zeros(slot)
            seg[0...attack] = c[a...(a + attack)]
            seg[attack...slot] = Numo::DFloat.cast(tail)
            seg
          }
        end

        # The :stretch fill's time map for a sound of +env+ (its
        # #envelope, one value per sample) drawn out to +out_len+ samples:
        # the input position (fractional) of each output sample and of the
        # end (+out_len+ + 1 values, from 0 to the input's length).  Each
        # input sample takes 1 + c × w output samples, its weight w from 0
        # where the level is within FILL_HOLD of +peak+ to 1 where it has
        # fallen by FILL_DECAY, plus FILL_EVEN; c makes the total
        # +out_len+.
        def fill_map(env, peak, out_len)
          n = env.length
          hold = FILL_HOLD.db_value
          span = FILL_DECAY.db_value - hold
          db = 20 * Numo::NMath.log10((env + 1e-12) / (peak + 1e-12))
          w = ((db - hold) / span).clip(0, 1) + FILL_EVEN
          times = Numo::DFloat.zeros(n + 1)
          times[1..] = (w * ((out_len - n) / w.sum) + 1).cumsum
          times[n] = out_len

          # (for each output sample, the last input sample at or before it)
          at = Numo::Int64.cast(times[0...n].ceil).bincount(minlength: out_len + 1)[0..out_len].cumsum - 1
          at = at.clip(0, n - 1)
          o = Numo::DFloat.new(out_len + 1).seq
          at + (o - times[at]) / (times[at + 1] - times[at])
        end

        # The level of +x+ over time, as many samples as +x+: the
        # magnitude of its analytic signal (no ripple at twice a low
        # tone's frequency, as a short RMS has on a kick's body),
        # squared, smoothed by two moving averages of +smooth+ samples
        # (shorter at the ends, where they average what is there), and
        # rooted.
        def envelope(x, smooth)
          x = Numo::DFloat.cast(x)
          n = x.length
          pad = MB::M.max(64, smooth * 2)
          padded = Numo::DFloat.zeros(n + 2 * pad)
          padded[pad...(pad + n)] = x
          e = (MB::Sound.analytic_signal(padded).abs**2)[pad...(pad + n)]
          return Numo::NMath.sqrt(e) if smooth < 2

          half = smooth / 2
          idx = Numo::Int64.new(n).seq
          lo = (idx - half).clip(0, n)
          hi = (idx + (smooth - half)).clip(0, n)
          count = Numo::DFloat.cast(hi - lo)
          2.times do
            c = Numo::DFloat.zeros(n + 1)
            c[1..] = e.cumsum
            e = (c[hi] - c[lo]) / count
          end
          Numo::NMath.sqrt(e.clip(0, nil))
        end

        # A slice from +a+ to +b+ filled out to +slot+ samples the way
        # fill: :stretch was before stretch-fixes-1 (fill: :cyclic): the
        # first +attack+ samples as they are, the rest through the fitted
        # cyclic stretch (Lofi.stretch).
        def cyclic_fill_slice(x, guide, a, b, slot, attack, cycle, crossfade, sample_rate)
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
