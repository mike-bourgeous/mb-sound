module MB
  module Sound
    module GraphNode
      class Reverb
        class Network
          # The exact Ruby mirror of MB::Sound::FastReverb::Network (see
          # ext/mb/sound/fast_reverb/fast_reverb.c for the algorithm): the
          # same double operations in the same order, rounding to float32
          # where the kernel stores floats (ring buffers and outputs), so
          # specs compare the two for exact equality.  About 1000x slower
          # than C; for specs and MB_SOUND_REVERB=ruby.
          class RubyKernel
            LFO_STEP = 16
            PARAM_COUNT = 12
            MASK64 = 0xFFFF_FFFF_FFFF_FFFF

            # A ring buffer of float32 values (Ruby Floats) with a
            # power-of-two capacity, indexed by the stream position.
            Line = Struct.new(:buf, :mask)

            # One LFO's state (see struct rev_lfo).
            Lfo = Struct.new(:phase, :value, :slope, :prev, :next_value, :scale)

            attr_reader :position

            def initialize(config)
              c = config
              @n = Integer(c.fetch(:lines))
              @stages = Integer(c.fetch(:stages))
              raise ArgumentError, 'Reverb lines must be a power of two from 1 to 1024' unless @n.between?(1, 1024) && (@n & (@n - 1)) == 0
              raise ArgumentError, 'Reverb stages must be 0 to 64' unless @stages.between?(0, 64)

              @rate = Float(c.fetch(:sample_rate))
              @feedback = !!c.fetch(:feedback)
              @rng = Integer(c.fetch(:seed)) & MASK64
              @diff_scale = Float(c.fetch(:diff_scale))
              @diff_mod = !!c.fetch(:diff_mod)
              @fdn_mod = !!c.fetch(:fdn_mod)
              @diff_shape = Integer(c.fetch(:diff_shape))
              @fdn_shape = Integer(c.fetch(:fdn_shape))
              @drive_mode = Integer(c.fetch(:drive_mode))
              @shimmer_window = Float(c.fetch(:shimmer_window))

              sn = @stages * @n
              @in_gain = floats(c, :in_gain, @n)
              @diff_delay = floats(c, :diff_delay, sn)
              @diff_pol = floats(c, :diff_polarity, sn)
              @diff_order = c.fetch(:diff_order).map { |v| Integer(v) }
              @diff = floats(c, :diff_capacity, sn).map { |need| line(need) }

              @tap = floats(c, :tap, @n)
              @loop = floats(c, :loop, @n)
              @gain = floats(c, :gain, @n)
              @normal = floats(c, :normal, @n)
              @order = c.fetch(:order).map { |v| Integer(v) }
              @fdn = floats(c, :fdn_capacity, @n).map { |need| line(@feedback ? need : 0) }
              @damp_a = c[:damp_coeffs] && floats(c, :damp_coeffs, @n)

              @dlfo = floats(c, :diff_rate_scale, sn).zip(floats(c, :diff_phase, sn)).map { |s, p| Lfo.new(p, 0.0, 0.0, 0.0, 0.0, s) }
              @flfo = floats(c, :fdn_rate_scale, @n).zip(floats(c, :fdn_phase, @n)).map { |s, p| Lfo.new(p, 0.0, 0.0, 0.0, 0.0, s) }
              @shim_phase = floats(c, :shimmer_phase, @n)

              @dlfo.each do |l|
                l.prev = rand_signed
                l.next_value = rand_signed
                l.value = shape(@diff_shape, l)
              end
              @flfo.each do |l|
                l.prev = rand_signed
                l.next_value = rand_signed
                l.value = shape(@fdn_shape, l)
              end

              @lp = Array.new(@n, 0.0)
              @hp = Array.new(@n, 0.0)
              @damp_hz = @hp_hz = @crush_bits = Float::NAN
              @damp_c = @hp_c = @crush_q = 0.0
              @position = 0
            end

            # See FastReverb::Network#process.
            def process(inputs, outputs, params, count)
              raise ArgumentError, "Need #{@n} inputs and outputs" unless inputs.length == @n && outputs.length == @n
              raise ArgumentError, "Need #{PARAM_COUNT} parameters" unless params.length == PARAM_COUNT

              ins = inputs.map { |v| signal(v) }
              par = params.map { |v| signal(v) }
              outs = outputs.map { |o| Array.new(count, 0.0) }
              x = Array.new(@n, 0.0)
              u = Array.new(@n, 0.0)

              count.times do |i|
                pos = @position
                diff_depth = at(par[0], i)
                fdn_depth = at(par[2], i)
                freeze = at(par[9], i)
                freeze = !(freeze > 0) ? 0.0 : (freeze > 1 ? 1.0 : freeze)

                if pos % LFO_STEP == 0
                  if @diff_mod
                    inc = at(par[1], i) / @rate
                    @dlfo.each { |l| lfo_step(l, @diff_shape, inc) }
                  end
                  if @fdn_mod && @feedback
                    inc = at(par[3], i) / @rate
                    @flfo.each { |l| lfo_step(l, @fdn_shape, inc) }
                  end
                end

                in_scale = 1.0 - freeze
                @n.times do |j|
                  x[j] = at(ins[j], i) * @in_gain[j] * in_scale
                end

                @stages.times do |s|
                  base = s * @n
                  @n.times do |j|
                    l = @diff[base + j]
                    l.buf[pos & l.mask] = f32(x[j])
                    d = @diff_delay[base + j]
                    d += diff_depth * (1.0 + @dlfo[base + j].value) if @diff_mod
                    d = clamp_delay(d, 0, l)
                    u[j] = read(l, pos, d) * @diff_pol[base + j]
                  end

                  h = 1
                  while h < @n
                    a = 0
                    while a < @n
                      (a...(a + h)).each do |b|
                        p = u[b]
                        q = u[b + h]
                        u[b] = p + q
                        u[b + h] = p - q
                      end
                      a += h << 1
                    end
                    h <<= 1
                  end

                  @n.times do |k|
                    x[k] = u[@diff_order[base + k]] * @diff_scale
                  end
                end

                if !@feedback
                  @n.times { |j| outs[j][i] = f32(x[j]) }
                else
                  size = at(par[10], i)
                  damp_hz = at(par[4], i)
                  hp_hz = at(par[5], i)
                  drive = at(par[6], i)
                  shimmer = at(par[7], i)
                  bits = at(par[11], i)

                  size = 0.0 unless size > 0
                  unless damp_hz == @damp_hz
                    @damp_hz = damp_hz
                    @damp_c = damp_hz > 0 ? 1.0 - Math.exp(-2.0 * Math::PI * damp_hz / @rate) : 1.0
                  end
                  unless hp_hz == @hp_hz
                    @hp_hz = hp_hz
                    @hp_c = hp_hz > 0 ? 1.0 - Math.exp(-2.0 * Math::PI * hp_hz / @rate) : 0.0
                  end
                  unless bits == @crush_bits
                    @crush_bits = bits
                    @crush_q = bits > 0 ? 2.0 ** bits : 0.0
                  end
                  shim_inc = 0.0
                  if shimmer > 0
                    shimmer = 1.0 if shimmer > 1
                    shim_inc = (at(par[8], i) - 1.0) / @shimmer_window
                  else
                    shimmer = 0.0
                  end

                  @n.times do |j|
                    l = @fdn[j]
                    mod = @fdn_mod ? fdn_depth * @flfo[j].value : 0.0
                    d = clamp_delay(@loop[j] * size + mod, 1, l)
                    v = read(l, pos, d)

                    if shimmer > 0
                      ph = @shim_phase[j] - shim_inc
                      ph -= ph.floor
                      @shim_phase[j] = ph
                      ph2 = ph + 0.5
                      ph2 -= 1.0 if ph2 >= 1.0
                      w = @shimmer_window
                      s1 = read(l, pos, clamp_delay(d + w * ph, 1, l))
                      s2 = read(l, pos, clamp_delay(d + w * ph2, 1, l))
                      shifted = s1 * (1.0 - (2.0 * ph - 1.0).abs) + s2 * (1.0 - (2.0 * ph2 - 1.0).abs)
                      v = v + (shifted - v) * shimmer
                    end

                    c = @damp_a ? @damp_a[j] : @damp_c
                    if c < 1.0
                      @lp[j] += c * (v - @lp[j])
                      v = @lp[j] + (v - @lp[j]) * freeze
                    end

                    if @hp_c > 0
                      @hp[j] += @hp_c * (v - @hp[j])
                      v = v - @hp[j] * (1.0 - freeze)
                    end

                    v = drive_shape(v * drive) / drive if drive > 0
                    if @crush_q > 0
                      t = v * @crush_q
                      t = t < 0 ? -((-t).floor.to_f) : t.floor.to_f
                      v = t / @crush_q
                    end

                    g = @gain[j]
                    g += (1.0 - g) * freeze
                    u[j] = x[j] + v * g
                  end

                  dot = 0.0
                  @n.times { |j| dot += @normal[j] * u[j] }
                  twice = 2.0 * dot
                  @n.times { |j| x[j] = u[j] - @normal[j] * twice }
                  @n.times do |j|
                    l = @fdn[j]
                    l.buf[pos & l.mask] = f32(x[@order[j]])
                  end

                  @n.times do |j|
                    l = @fdn[j]
                    mod = @fdn_mod ? fdn_depth * @flfo[j].value : 0.0
                    d = clamp_delay(@tap[j] * size + mod, 0, l)
                    outs[j][i] = f32(read(l, pos, d))
                  end
                end

                @dlfo.each { |l| l.value += l.slope } if @diff_mod
                @flfo.each { |l| l.value += l.slope } if @fdn_mod && @feedback

                @position = pos + 1
              end

              outputs.each_with_index do |o, j|
                o[0...count] = outs[j]
              end
              outputs
            end

            # The LFOs' current values, as FastReverb::Network#lfo_values.
            def lfo_values
              [@dlfo.map(&:value), @flfo.map(&:value)]
            end

            private

            def floats(c, key, len)
              v = c.fetch(key)
              raise ArgumentError, "Reverb config :#{key} needs #{len} values, got #{v.length}" unless v.length == len
              v.map { |f| Float(f) }
            end

            def line(need)
              cap = 16
              cap <<= 1 while cap < need + 4
              Line.new(Array.new(cap, 0.0), cap - 1)
            end

            def f32(x)
              [x].pack('f').unpack1('f')
            end

            # The C kernel reads Numerics as doubles and NArrays as float32.
            def signal(v)
              case v
              when nil
                0.0
              when Numeric
                v.to_f
              when Numo::NArray
                v = Numo::SFloat.cast(v.real) unless v.is_a?(Numo::SFloat)
                v.to_a
              else
                raise ArgumentError, "Invalid signal #{v.class}"
              end
            end

            def at(sig, i)
              sig.is_a?(Array) ? sig[i] : sig
            end

            def rand_signed
              z = @rng = (@rng + 0x9e3779b97f4a7c15) & MASK64
              z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & MASK64
              z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & MASK64
              z ^= z >> 31
              (z >> 11) * (1.0 / 9007199254740992.0) * 2.0 - 1.0
            end

            def shape(shape, l)
              p = l.phase
              case shape
              when 0, 1
                t = if p < 0.25
                  4.0 * p
                elsif p < 0.75
                  2.0 - 4.0 * p
                else
                  4.0 * p - 4.0
                end
                return t if shape == 1

                t2 = t * t
                t * (1.5707963267948966 - t2 * (0.6459640975062462 - t2 * (0.07969262624616703 - t2 * 0.004681754135318687)))
              when 2
                l.prev + (l.next_value - l.prev) * p
              else
                s = p * p * (3.0 - 2.0 * p)
                l.prev + (l.next_value - l.prev) * s
              end
            end

            def lfo_step(l, shape, inc)
              l.phase += inc * l.scale * LFO_STEP
              if !(l.phase < 1.0) || l.phase < 0
                if shape >= 2
                  while l.phase >= 1.0
                    l.phase -= 1.0
                    l.prev = l.next_value
                    l.next_value = rand_signed
                  end
                  l.phase = 0.0 if l.phase < 0
                else
                  l.phase = l.phase - 1.0 * l.phase.floor
                end
              end
              target = shape(shape, l)
              l.slope = (target - l.value) * (1.0 / LFO_STEP)
            end

            def read(l, pos, d)
              fl = d.floor.to_f
              di = fl.to_i
              t = d - fl
              b = l.buf
              m = l.mask
              return b[(pos - di) & m] if t == 0

              ym1 = b[(pos - di + 1) & m]
              y0 = b[(pos - di) & m]
              y1 = b[(pos - di - 1) & m]
              y2 = b[(pos - di - 2) & m]
              c1 = 0.5 * (y1 - ym1)
              c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2
              c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)
              ((c3 * t + c2) * t + c1) * t + y0
            end

            def clamp_delay(d, lo, l)
              hi = l.mask.to_f - 3.0
              d = lo.to_f unless d >= lo
              d = hi if d > hi
              d = lo + 1.0 if d < lo + 1.0 && d != d.floor
              d
            end

            def drive_shape(u)
              case @drive_mode
              when 1
                u > 1.0 ? 1.0 : (u < -1.0 ? -1.0 : u)
              when 2
                t = (u + 1.0) * 0.25
                t -= t.floor
                1.0 - 4.0 * (t - 0.5).abs
              else
                return 1.0 if u >= 3.0
                return -1.0 if u <= -3.0

                u * (27.0 + u * u) / (27.0 + 9.0 * u * u)
              end
            end
          end
        end
      end
    end
  end
end
