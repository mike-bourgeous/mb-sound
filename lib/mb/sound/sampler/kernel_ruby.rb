module MB
  module Sound
    module Sampler
      # The exact Ruby mirror of MB::Sound::FastSampler.play (see
      # ext/mb/sound/fast_sampler/fast_sampler.c for the arguments): the same
      # double operations in the same order, signal inputs read as float32
      # values, table reads through Wavetable::KernelRuby, so specs compare
      # the two for equality.
      module KernelRuby
        # Region columns (FastSampler::REGION_COLS of them; see
        # Sampler::Instrument#region_table).
        TABLE, LOKEY, HIKEY, LOVEL, HIVEL, SEQ_LENGTH, SEQ_POSITION, LORAND, HIRAND, ROOT, KEYTRACK, TUNE, GAIN,
          START, STOP, LOOP_START, LOOP_END, LOOP_MODE, REVERSE, FADE_IN, FADE_OUT, VELTRACK, RATE, OFFSET = (0..23).to_a

        # One note's state (as in C): SMP_VOICE values.
        VOICE = 10

        # The tail's samples left.
        TAIL_LEFT = 2 * VOICE

        # The state's length.
        STATE_LENGTH = 2 * VOICE + 1

        # A note: active, region, pos, dir, base, gain, nhz, inloop, released,
        # speed, and its table slot.
        Voice = Struct.new(:active, :region, :pos, :dir, :base, :gain, :nhz, :inloop, :released, :speed, :slot)

        module_function

        def play(out, specs, regions, state, counters, rng, inputs, config)
          raise ArgumentError, 'Sampler inputs are [trigger, number, freq, gate, start]' unless inputs.length == 5
          raise ArgumentError, 'Sampler config is [a4, declick, nkeys, interpolation, sinc, transpose]' unless config.length == 6

          count = out.length
          rows = regions.shape[0]
          regs = Array.new(rows) { |k| regions[k, true].to_a }
          a4, declick, nkeys, interp, _sinc, transpose = config
          a4 = a4.to_f
          declick = Integer(declick)
          transpose = transpose.to_f
          ctx = { specs: specs, regions: regs, nkeys: Integer(nkeys), interp: interp }

          trig_s, trig_a = Wavetable::KernelRuby.signal(inputs[0], count)
          num_s, num_a = Wavetable::KernelRuby.signal(inputs[1], count)
          has_freq = !inputs[2].nil?
          freq_s, freq_a = Wavetable::KernelRuby.signal(inputs[2], count)
          has_gate = !inputs[3].nil?
          gate_s, gate_a = Wavetable::KernelRuby.signal(inputs[3], count)
          start_s, start_a = Wavetable::KernelRuby.signal(inputs[4], count)

          cur = get(state, 0)
          tail = get(state, VOICE)
          left = state[TAIL_LEFT]
          cur.slot = 0
          tail.slot = 1
          seed = [rng[0].to_i]

          values = Array.new(count)
          count.times do |i|
            t = trig_a ? trig_a[i] : trig_s
            n = num_a ? num_a[i] : num_s

            if t > 0
              slot = cur.slot
              if cur.active && declick > 0
                tail = cur.dup
                left = declick.to_f
                slot = 1 - cur.slot
              elsif tail.active
                slot = 1 - tail.slot
              end
              vel = t > 1 ? 1.0 : t
              note_on(ctx, cur, slot, n, vel, start_a ? start_a[i] : start_s, counters, seed, a4, transpose)
            end

            cur.released = true if has_gate && (gate_a ? gate_a[i] : gate_s) <= 0

            v = 0.0
            if cur.active
              sp = cur.base
              sp = cur.base * ((freq_a ? freq_a[i] : freq_s) / cur.nhz) if has_freq && cur.nhz > 0
              cur.speed = sp
              v = step(ctx, cur, sp)
            end
            if tail.active
              g = left / declick.to_f
              tv = step(ctx, tail, tail.speed)
              v = v + tv * g
              left = left - 1
              tail.active = false if left <= 0
            end

            values[i] = v
          end

          put(state, 0, cur)
          put(state, VOICE, tail)
          state[TAIL_LEFT] = left
          rng[0] = seed[0]

          out[true] = values
          out
        end

        def get(state, o)
          Voice.new(
            state[o] != 0, state[o + 1].to_i, state[o + 2], state[o + 3], state[o + 4], state[o + 5], state[o + 6],
            state[o + 7] != 0, state[o + 8] != 0, state[o + 9], 0
          )
        end

        def put(state, o, v)
          state[o] = v.active ? 1 : 0
          state[o + 1] = v.region
          state[o + 2] = v.pos
          state[o + 3] = v.dir
          state[o + 4] = v.base
          state[o + 5] = v.gain
          state[o + 6] = v.nhz
          state[o + 7] = v.inloop ? 1 : 0
          state[o + 8] = v.released ? 1 : 0
          state[o + 9] = v.speed
        end

        def loops?(r, v)
          return false unless r[LOOP_END] > r[LOOP_START]
          mode = r[LOOP_MODE]
          mode == Sampler::LOOP_MODES[:forward] || mode == Sampler::LOOP_MODES[:ping_pong] ||
            (mode == Sampler::LOOP_MODES[:release] && !v.released)
        end

        def step(ctx, v, sp)
          r = ctx[:regions][v.region]
          start = r[START]
          stop = r[STOP]
          p = v.pos

          m = sp.abs
          spec = ctx[:specs][r[TABLE].to_i]
          re = Wavetable::KernelRuby.value(spec, p, m, 0.0, ctx[:interp])

          g = v.gain
          fi = r[FADE_IN]
          if fi > 0
            trav = v.dir > 0 ? p - start : (stop - 1) - p
            g = g * (trav / fi) if trav < fi
          end

          loops = loops?(r, v)
          fo = r[FADE_OUT]
          if fo > 0 && !loops
            rem = v.dir > 0 ? stop - p : (p + 1) - start
            g = g * (rem / fo) if rem < fo
          end

          val = re * g

          np = p + v.dir * sp
          if loops
            ls = r[LOOP_START]
            le = r[LOOP_END]
            len = le - ls
            v.inloop = true if !v.inloop && np >= ls && np < le
            if v.inloop
              if r[LOOP_MODE] == Sampler::LOOP_MODES[:ping_pong]
                if np >= le
                  np = le - (np - le)
                  v.dir = -v.dir
                  np = ls if np < ls
                elsif np < ls
                  np = ls + (ls - np)
                  v.dir = -v.dir
                  np = ls if np >= le
                end
              elsif np >= le || np < ls
                np = ls + Wavetable::KernelRuby.fwrap(np - ls, len)
              end
            end
          end

          v.active = false if np >= stop || np < start
          v.pos = np
          val
        end

        def note_on(ctx, v, slot, n, vel, frac, counters, seed, a4, transpose)
          rnd = Tone.noise_random(seed)
          v127 = (vel * 127.0 + 0.5).floor.to_f
          v127 = 127.0 if v127 > 127
          v127 = 0.0 if v127 < 0

          regs = ctx[:regions]
          nkeys = ctx[:nkeys]
          j = -1
          expo = 0.0
          rev = false
          chop = n >= 128

          if !chop
            key = (n + 0.5).floor
            count = 0.0
            if key >= 0 && key < 128
              counters[key] = counters[key] + 1
              count = counters[key]
            end
            nkeys.times do |k|
              r = regs[k]
              next if key < r[LOKEY] || key > r[HIKEY]
              next if v127 < r[LOVEL] || v127 > r[HIVEL]
              next if rnd < r[LORAND] || rnd >= r[HIRAND]
              sl = r[SEQ_LENGTH].to_i
              next if sl > 1 && (count.to_i - 1) % sl + 1 != r[SEQ_POSITION].to_i
              j = k
              break
            end
            if j >= 0
              r = regs[j]
              expo = ((n - r[ROOT]) * r[KEYTRACK] + r[TUNE] + transpose) / 12.0
            end
          else
            q = (n / 128.0).floor.to_f
            code = q.to_i - 1
            slice = code / 2
            rev = code.odd?
            semis = n - q * 128.0 - 64.0
            if slice < regs.length - nkeys
              j = nkeys + slice
              r = regs[j]
              if v127 < r[LOVEL] || v127 > r[HIVEL]
                j = -1
              else
                expo = (semis + r[TUNE] + transpose) / 12.0
              end
            end
          end

          v.active = false
          return if j < 0

          r = regs[j]
          start = r[START]
          stop = r[STOP]
          off = r[OFFSET] + frac * (stop - start)
          reverse = (r[REVERSE] != 0) != rev

          v.region = j
          v.dir = reverse ? -1.0 : 1.0
          v.pos = reverse ? (stop - 1) - off : start + off
          v.base = 2.0**expo * r[RATE]
          vt = r[VELTRACK]
          vv = v127 / 127.0
          v.gain = r[GAIN] * ((1.0 - vt) + vt * (vv * vv))
          v.nhz = chop ? 0.0 : a4 * 2.0**((n - 69.0) / 12.0)
          v.released = false
          v.speed = v.base
          v.inloop = r[LOOP_END] > r[LOOP_START] && v.pos >= r[LOOP_START] && v.pos < r[LOOP_END]
          v.slot = slot
          v.active = v.pos >= start && v.pos < stop
        end
      end
    end
  end
end
