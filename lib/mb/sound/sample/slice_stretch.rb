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
      # with :stretch the slice keeps its first +attack+ samples and the
      # rest is drawn out to the next hit by a cyclic stretch, one of two
      # ways, picked slice by slice (#fill_kind): :even stretches
      # everything after the attack evenly (#even_fill_slice: the fitted
      # cyclic stretch), so what is inside the slice (a second note, a
      # tone that swells) lands on its stretched time; :decay
      # (#fill_slice), for a slice that is one hit dying down, keeps the
      # hit's body at its length and draws out what it has died down to,
      # its level following the decay (an even stretch plays part of a
      # kick's body twice).  Either can be asked for by name.  A slice
      # shorter than the attack and two cycles is filled with a shorter
      # attack and shorter cycles (down to FILL_SHORTEST).  Speeding up
      # (+ratio+ < 1)
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
      # Two settings shape those fades.  +slot_fade+ (nil, or a share of
      # 0 to 1) is for slices cut short: instead of the fixed +fade+,
      # such a slice plays as it is for the rest of its slot (the time
      # from its start to the next slice's) and crossfades over that
      # share of the slot into the audio that led up to the next cut in
      # the input, fade-out and fade-in the same length, however short
      # or long the slot.  A hit just before a cut then keeps its
      # distance to that cut (with the short fixed fade it is cut off, or
      # plays late).  +fade_law+ is how every pair of fades adds up:
      # :linear (default; gains that sum to 1, raised cosines) or :power
      # (their square roots: a cosine going out and a sine coming in,
      # equal power, for a fade between sounds that are not alike).
      # `slot_fade: 2/3r, fade_law: :power` is what renders of sliced
      # loops played faster by a loop-based sequencer measured as (the
      # first third of each slot as in the file, then an equal-power
      # crossfade into the lead-in of the next hit).  Slices drawn out,
      # and slices that follow on, are as without it.
      #
      # +positions+ gives each cut its own place in the output (samples)
      # instead of the cut × +ratio+, for slices moved off the grid of
      # the stretch (a groove); each slot is then cut short, drawn out
      # (+fill+), or left to follow on by its own length.
      #
      # Pure Ruby + Numo (per slice copies; the fills plan and play a
      # cyclic stretch per slice).  Every channel cuts in the same places.
      module SliceStretch
        # The default fade at a slice's end (seconds).
        FADE = 0.004

        # +fade_law+ values: :linear (the two sides' gains sum to 1) and
        # :power (their squares do: equal power), as GraphNode#blend's
        # +curve:+.
        LAWS = [:linear, :power].freeze

        # With fill: :stretch, the part of each slice kept exactly before
        # its decay is stretched (seconds).
        ATTACK = 0.015

        # +fill+ values: :gap (silence after each slice), :stretch (each
        # slice drawn out, :even or :decay as #fill_kind picks), :even
        # (the fitted cyclic stretch of everything after the attack), and
        # :decay (the hit whole, what it has died down to drawn out along
        # the decay's envelope).
        FILLS = [:gap, :stretch, :even, :decay].freeze

        # The shortest slice (seconds) the :stretch fill fills: shorter
        # ones play with a gap.  A slice too short for the usual attack
        # and two cycles keeps a quarter of itself as its attack and
        # cycles half of the rest (a one-shot saved as a loop has a
        # marker every 58 ms: none of its slices was filled before).
        FILL_SHORTEST = 0.005

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

        # fill: :stretch gives a slice the :decay fill when it is one hit
        # that dies down: its level falls by FILL_DIES after its loudest
        # point, and nothing comes up again by FILL_SECOND (to within
        # FILL_DECAY of the loudest).  On a generated drum loop that is
        # its eight kick slices, where the even fill replayed the kick's
        # body, and none of the others; on a tonal drum loop with a
        # shaker 8 slices of 49.
        FILL_DIES = -15.db
        FILL_SECOND = 6.db
        FILL_DECAY = -20.db
        FILL_EVEN = 0.02

        module_function

        # +channels+ (DFloat or SFloat arrays in play order) stretched by
        # +ratio+, cut at +cuts+ (sample positions, 0 first; the end is
        # added).  +fade+ in samples; +attack+, +cycle+, and +crossfade+
        # (the fill's stretch) in samples.  +slot_fade+ (nil or 0..1) and
        # +fade_law+ (LAWS) as the module says; +positions+ (nil, or one
        # output sample per cut, in the cuts' order) as #places reads
        # them.  Returns Arrays of SFloat.
        def stretch(channels, ratio, cuts, fade:, fill: :gap, attack: 720, cycle: 1200, crossfade: 144, sample_rate: 48000, slot_fade: nil, fade_law: :linear, positions: nil)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio.is_a?(Numeric) && ratio > 0
          raise ArgumentError, "fill: is one of #{FILLS.inspect} (got #{fill.inspect})" unless FILLS.include?(fill)
          raise ArgumentError, "fade_law: is one of #{LAWS.inspect} (got #{fade_law.inspect})" unless LAWS.include?(fade_law)
          unless slot_fade.nil? || (slot_fade.is_a?(Numeric) && slot_fade >= 0 && slot_fade <= 1)
            raise ArgumentError, "slot_fade: is a share of each slot, from 0 to 1 (got #{slot_fade.inspect})"
          end

          x = channels.map { |c| Numo::DFloat.cast(c) }
          len = x[0].length
          n_out = (len * ratio).round
          p, q = places(cuts, positions, ratio, len, n_out)

          out = x.map { Numo::DFloat.zeros(n_out) }
          guide = fill == :gap ? nil : x.sum / x.length
          joined = [] # whether slice i follows on from slice i - 1
          lead = []   # the pre-roll into slice i, where the slot before it sets it (slot_fade)
          shortest = MB::M.max(64, (FILL_SHORTEST * sample_rate).round)

          (p.length - 1).times do |i|
            a, b = p[i], p[i + 1]
            qa = q[i]
            slot = q[i + 1] - qa
            own = b - a
            next if slot <= 0

            segs =
              if fill != :gap && slot > own && own >= shortest
                att, cyc, xf = attack, cycle, crossfade
                if own - attack < 2 * cycle
                  # (a short slice: a quarter of it as its attack, cycles
                  # of half the rest)
                  att = MB::M.min(attack, own / 4)
                  cyc = MB::M.min(cycle, (own - att) / 2)
                  xf = MB::M.min(crossfade, cyc / 4)
                end
                kind = fill == :stretch ? fill_kind(guide, a, b, sample_rate) : fill
                if kind == :decay
                  fill_slice(x, guide, a, b, slot, att, cyc, xf, sample_rate)
                else
                  even_fill_slice(x, guide, a, b, slot, att, cyc, xf, sample_rate)
                end
              else
                m = MB::M.min(slot, own)
                x.map { |c| c[a...(a + m)].dup }
              end
            m = segs[0].length
            continuous = m == own && slot == own
            joined[i + 1] = continuous

            fo =
              if continuous
                0
              elsif slot_fade && slot < own
                # (a slice cut short: it fades over its share of the
                # slot, and the lead-in to the next cut, which is this
                # slice's own end, fades in over the same samples)
                lead[i + 1] = (slot * slot_fade).round
              else
                MB::M.min(fade, m / 2)
              end
            segs.each_with_index do |seg, ch|
              seg[(m - fo)...m] *= ramp(fo, false, fade_law) if fo > 0
              out[ch][qa...(qa + m)] += seg
            end
          end

          # Pre-rolls into slices that don't follow on from the one before
          # (the first slice's from the loop's end, at the output's end)
          (p.length - 1).times do |i|
            next if joined[i]
            if i == 0
              next if joined[p.length - 1] || n_out < 2
              f = lead[p.length - 1] || [fade, len / 2, n_out / 2].min
              x.each_with_index { |c, ch| out[ch][(n_out - f)...n_out] += c[(len - f)...len] * ramp(f, true, fade_law) } if f > 0
            else
              f = lead[i] || [fade, p[i], q[i]].min
              x.each_with_index { |c, ch| out[ch][(q[i] - f)...q[i]] += c[(p[i] - f)...p[i]] * ramp(f, true, fade_law) } if f > 0
            end
          end

          out.map { |o| Numo::SFloat.cast(o) }
        end

        # Where the slices are cut and where each starts in the output:
        # [input positions, output positions], both from 0 to the end
        # (+len+, +n_out+), for +cuts+ (cuts at or outside the ends are
        # left out).  Without +positions+ a cut lands at itself × +ratio+,
        # rounded; with them (one output sample per cut, in the cuts'
        # order) where its position says: within the output, never
        # before the cut before it, and a cut at 0 at 0.
        def places(cuts, positions, ratio, len, n_out)
          cuts = cuts.map { |c| Integer(c) }
          if positions.nil?
            p = (cuts.select { |c| c > 0 && c < len } + [0, len]).uniq.sort
            q = p.map { |c| (c * ratio).round }
            q[-1] = n_out
            return [p, q]
          end

          raise ArgumentError, "positions: takes one output position per cut (#{cuts.length} cuts, got #{positions.length} positions)" unless positions.length == cuts.length
          at = { 0 => 0, len => n_out }
          cuts.zip(positions.map { |v| Integer(v) }) do |c, v|
            next if c < 0 || c > len
            raise ArgumentError, "positions: a cut at the start stays at 0 (got #{v})" if c == 0 && v != 0
            raise ArgumentError, "positions: a cut at the end stays at the end, #{n_out} (got #{v})" if c == len && v != n_out
            raise ArgumentError, "positions: the cut at #{c} has two positions (#{at[c]} and #{v})" if at.key?(c) && at[c] != v
            raise ArgumentError, "positions: are within the output, 0 to #{n_out} (got #{v})" unless v >= 0 && v <= n_out
            at[c] = v
          end
          p = at.keys.sort
          q = p.map { |c| at[c] }
          q.each_cons(2).with_index { |(u, v), i| raise ArgumentError, "positions: run forward with their cuts (the cut at #{p[i + 1]} is at #{v}, before #{u})" if v < u }
          [p, q]
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
        # nothing sounds like a second hit.  (Before stretch-fixes-1 the
        # fill was the plain cyclic stretch of everything after the
        # attack: a kick's body played at its old time and then again, in
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

        # A slice from +a+ to +b+ filled out to +slot+ samples evenly
        # (fill: :even): the first +attack+ samples as they are, the rest
        # through the fitted cyclic stretch (Lofi.stretch: cycles a whole
        # number of the sound's periods, each starting where the sound
        # matches what would have followed), so everything in the slice
        # lands near its stretched time.
        def even_fill_slice(x, guide, a, b, slot, attack, cycle, crossfade, sample_rate)
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

        # Which fill a slice from +a+ to +b+ of +guide+ gets under fill:
        # :stretch.  :decay if the slice is one hit that dies down: after
        # its loudest point its level (#envelope) falls by FILL_DIES or
        # more, and no second sound comes up after that (a rise of
        # FILL_SECOND from the lowest level so far, to within FILL_DECAY
        # of the loudest).  Else :even: a slice that stays loud, or holds
        # more than one sound, is drawn out evenly, so what is inside it
        # lands on its stretched time.
        def fill_kind(guide, a, b, sample_rate)
          lead = MB::M.min(a, (4 * FILL_SMOOTH * sample_rate).round)
          env = envelope(guide[(a - lead)...b], (FILL_SMOOTH * sample_rate).round)[lead..]
          top = env.max
          return :even if top <= 0

          level = (env / top).to_a
          dies = FILL_DIES.to_f
          second = FILL_SECOND.to_f
          floor = FILL_DECAY.to_f
          lowest = 1.0
          level[level.index(level.max)..].each do |v|
            lowest = v if v < lowest
            return :even if v >= floor && v >= lowest * second
          end
          lowest <= dies ? :decay : :even
        end

        # A fade of +n+ samples (in or out): a raised cosine (+law+
        # :linear: with its mirror it sums to 1), or its square root
        # (:power: a quarter of a sine; the squares sum to 1).
        def ramp(n, rising, law = :linear)
          t = (Numo::DFloat.new(n).seq + 0.5) / n
          w = 0.5 - 0.5 * Numo::NMath.cos(t * Math::PI)
          w = Numo::NMath.sqrt(w) if law == :power
          rising ? w : w.reverse
        end
      end
    end
  end
end
