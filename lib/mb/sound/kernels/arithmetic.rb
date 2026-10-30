module MB
  module Sound
    module Kernels
      # The Ruby mirrors of MB::Sound::FastArithmetic (kernels-1): the same
      # checks (each returns nil without writing where the C kernel does, so
      # callers fall back to their Numo code alike) and the same values,
      # computed with the Numo operations the C kernels were written to
      # match (ext/mb/sound/fast_arithmetic/fast_arithmetic.c describes
      # each).  Float32 steps stay in SFloat arithmetic, so every product and
      # sum rounds as the kernel's.
      module Arithmetic
        REAL = [Numo::SFloat, Numo::DFloat].freeze
        TYPES = [Numo::SFloat, Numo::DFloat, Numo::SComplex, Numo::DComplex].freeze
        COMPLEX = [Numo::SComplex, Numo::DComplex].freeze

        # Input types each output type reads directly.
        INPUTS = {
          Numo::SFloat => [Numo::SFloat],
          Numo::DFloat => [Numo::DFloat],
          Numo::SComplex => [Numo::SComplex, Numo::SFloat],
          Numo::DComplex => [Numo::DComplex, Numo::DFloat],
        }.freeze

        module_function

        def narray?(v, types = TYPES)
          v.is_a?(Numo::NArray) && types.include?(v.class)
        end

        def contiguous1?(v)
          v.ndim == 1 && v.contiguous?
        end

        def shape_ok?(v, length)
          v.ndim == 1 && v.size == length && v.contiguous?
        end

        def writable?(v)
          contiguous1?(v) && !v.frozen?
        end

        def real_number?(v)
          v.is_a?(Float) || v.is_a?(Integer)
        end

        # A Numeric as the kernel reads it: [real, imaginary] doubles.
        def parts(n)
          n.is_a?(Complex) ? [n.real.to_f, n.imag.to_f] : [n.to_f, 0.0]
        end

        # (float)x as a Float.
        def f32(x)
          [x.to_f].pack('f').unpack1('f')
        end

        # The output type of +out+ for .product and .mix (nil: decline).
        def checked_type(out, sampled)
          raise TypeError, 'Inputs must be an Array of [buffer, extra] Arrays' unless sampled.is_a?(Array)
          return nil unless narray?(out) && contiguous1?(out) && !out.frozen?

          ok = sampled.all? do |pair|
            pair.is_a?(Array) && pair.length >= 1 && narray?(pair[0]) && INPUTS[out.class].include?(pair[0].class) &&
              shape_ok?(pair[0], out.size)
          end
          ok ? out.class : nil
        end

        # The constant as the output type stores it.
        def constant_for(type, cr, ci)
          COMPLEX.include?(type) ? Complex(cr, ci) : cr
        end

        def product(out, constant, sampled)
          type = checked_type(out, sampled)
          return nil unless type

          cr, ci = parts(constant)
          return nil if ci != 0 && REAL.include?(type)

          if COMPLEX.include?(type)
            complex = ci != 0
            sampled.each do |(v)|
              next unless COMPLEX.include?(v.class)
              return nil if complex

              complex = true
            end
          end

          out.fill(constant_for(type, cr, ci))
          sampled.each { |(v)| out[true] = out * v }
          out
        end

        def mix(out, constant, sampled)
          type = checked_type(out, sampled)
          return nil unless type

          real = REAL.include?(type)
          cr, ci = parts(constant)
          return nil if ci != 0 && real

          sampled.each do |pair|
            return nil if pair.length < 2

            v, gain = pair
            return nil if !gain.is_a?(Numeric) || (real && gain.is_a?(Complex))

            if COMPLEX.include?(v.class) && gain.is_a?(Complex) && gain != 1
              return nil if parts(gain)[1] != 0
            end
          end

          out.fill(constant_for(type, cr, ci))
          sampled.each do |(v, gain)|
            v = type.cast(v) unless v.class == type # (a real input to a complex output: (x, 0))
            if gain == 1
              out[true] = out + v
            else
              gr, gi = parts(gain)
              out[true] = out + v * (real ? gr : Complex(gr, gi))
            end
          end
          out
        end

        def copy(out, src)
          return nil unless narray?(out) && src.class == out.class && contiguous1?(out)
          return nil unless shape_ok?(src, out.size) && !out.frozen?

          out[true] = src if out.size > 0
          out
        end

        def cast_copy(out, src)
          return nil unless narray?(out, REAL) && writable?(out) && narray?(src, REAL)
          return nil unless shape_ok?(src, out.size)

          out[true] = src if out.size > 0
          out
        end

        def ease_plain(out, data, in_lo, in_scale, kind, clamp, out_scale, out_lo)
          return nil unless out.class == Numo::SFloat && writable?(out)
          return nil unless narray?(data, REAL) && shape_ok?(data, out.size)
          return nil unless [in_lo, in_scale, out_scale, out_lo].all?(Float) && kind.is_a?(Integer)
          return nil unless kind == 0 || kind == 1

          x = Numo::DFloat.cast(data)
          x = x - in_lo
          x = x * in_scale
          x = x.clip(0.0, 1.0) if clamp
          y = x
          y = (x * x) * ((x * -2.0) + 3.0) if kind == 1
          y = y * out_scale
          y = y + out_lo
          out[true] = y
          out
        end

        def knob_ramp(out, pos, n, j0, length, curve, exp, mul, add1, add2, to)
          return nil unless out.class == Numo::SFloat && writable?(out)
          return nil unless [pos, n, j0, length, curve].all?(Integer) && [mul, add1, add2, to].all?(Float)
          return nil if pos < 0 || n < 0 || pos + n > out.size || length <= 0 || (curve != 0 && curve != 1)
          return out if n == 0

          ends = j0 + n >= length
          t = Numo::DFloat.new(n).seq(j0 + 1)
          t = t / length.to_f
          t = t.clip(0.0, 1.0) if ends
          x = t
          x = (x * x) * ((x * -2.0) + 3.0) if curve == 1
          x = x * mul
          x = x + add1
          if exp
            x = x + add2
            x = Numo::NMath.exp(x)
          end
          x[t.ge(1.0)] = to if ends
          out[pos...(pos + n)] = x
          out
        end

        def min_max(buf, result)
          raise TypeError, "wrong argument type #{result.class} (expected Array)" unless result.is_a?(Array)
          return nil unless narray?(buf, REAL) && contiguous1?(buf) && buf.size > 0

          lo = buf.min.to_f
          hi = buf.max.to_f
          result[0] = lo unless same_bits?(result[0], lo)
          result[1] = hi unless same_bits?(result[1], hi)
          result
        end

        # (min_max keeps a stored Float with the same bits, as the kernel does.)
        def same_bits?(old, v)
          old.is_a?(Float) && [old].pack('d') == [v].pack('d')
        end

        def divide(out, divisor)
          return nil unless narray?(out, REAL) && writable?(out)

          if real_number?(divisor)
            out[true] = out / divisor.to_f
            return out
          end
          return nil unless divisor.is_a?(Numo::NArray) && divisor.class == out.class && shape_ok?(divisor, out.size)

          out[true] = out / divisor
          out
        end

        def power(out, exponent)
          return nil unless narray?(out, REAL) && writable?(out)

          if exponent.is_a?(Float)
            out[true] = out**exponent
            return out
          end
          return nil unless exponent.is_a?(Numo::NArray) && exponent.class == out.class && shape_ok?(exponent, out.size)

          out[true] = out**exponent
          out
        end

        def power_fast(out, exponent)
          return nil unless out.class == Numo::SFloat && writable?(out)

          scalar = exponent.is_a?(Float)
          return nil unless scalar || (exponent.class == Numo::SFloat && shape_ok?(exponent, out.size))
          return out if out.size == 0

          b = scalar ? Numo::SFloat.new(out.size).fill(exponent) : exponent
          out[true] = Plan::VecExp2.pow(out, b)
          out
        end

        def circular_read(source, offset, length, target)
          return nil unless narray?(source) && target.class == source.class && offset.is_a?(Integer) && length.is_a?(Integer)
          return nil unless contiguous1?(source) && writable?(target)

          n = source.size
          return nil if offset < -n || offset >= n || length < 1 || length > n || length > target.size

          offset += n if offset < 0
          before = n - offset
          if length <= before
            target[0...length] = source[offset...(offset + length)]
          else
            target[0...before] = source[offset...n]
            target[before...length] = source[0...(length - before)]
          end
          target
        end

        def circular_write(target, source, offset)
          return nil unless narray?(target) && source.class == target.class && offset.is_a?(Integer)
          return nil unless contiguous1?(source) && writable?(target)

          n = target.size
          length = source.size
          return nil if offset < -n || offset >= n || length < 1 || length > n

          offset += n if offset < 0
          before = n - offset
          if length <= before
            target[offset...(offset + length)] = source
          else
            target[offset...n] = source[0...before]
            target[0...(length - before)] = source[before...length]
          end
          target
        end

        def wet_dry(out, delayed, wet, data, dry)
          return nil unless out.class == Numo::SFloat && writable?(out)
          return nil unless delayed.class == Numo::SFloat && shape_ok?(delayed, out.size) && real_number?(wet)

          use_dry = !dry.nil?
          return nil if use_dry && !(real_number?(dry) && data.class == Numo::SFloat && shape_ok?(data, out.size))

          w = f32(wet)
          if use_dry
            out[true] = (delayed * w) + (data * f32(dry))
          else
            out[true] = delayed * w
          end
          out
        end

        def complex_part(out, src, imag)
          ok = (src.class == Numo::SComplex && out.class == Numo::SFloat) || (src.class == Numo::DComplex && out.class == Numo::DFloat)
          return nil unless ok && writable?(out) && shape_ok?(src, out.size)

          out[true] = imag ? src.imag : src.real
          out
        end

        def pan(law, position, input, gains, outs)
          return nil unless gains.is_a?(Array) && gains.length == 2 && outs.is_a?(Array) && outs.length == 2
          return nil unless input.class == Numo::SFloat && contiguous1?(input)

          length = input.size
          return nil unless position.class == Numo::SFloat && shape_ok?(position, length)
          return nil unless (gains + outs).all? { |w| w.class == Numo::SFloat && writable?(w) && w.size == length }

          law = Integer(law)
          return nil if law < 0 || law > 2

          p = position.clip(-1.0, 1.0)
          gl, gr = gains
          if law == 0
            angle = (p + 1.0) * f32(Math::PI / 4)
            gl[true] = Numo::NMath.cos(angle)
            gr[true] = Numo::NMath.sin(angle)
          else
            l = (1.0 - p) * 0.5
            r = (p + 1.0) * 0.5
            if law == 2
              l = l**0.75
              r = r**0.75
            end
            gl[true] = l
            gr[true] = r
          end
          outs[0][true] = gl * input
          outs[1][true] = gr * input
          outs
        end

        def scale(out, gain)
          return nil unless (out.class == Numo::SFloat || out.class == Numo::SComplex) && contiguous1?(out) && !out.frozen?

          if real_number?(gain)
            g = f32(gain)
          elsif gain.class == Numo::SFloat && shape_ok?(gain, out.size)
            g = gain
          else
            return nil
          end
          out[true] = out * (g.is_a?(Numo::NArray) && out.class == Numo::SComplex ? Numo::SComplex.cast(g) : g)
          out
        end

        def add_at(out, offset, data, length, ramp)
          return nil unless offset.is_a?(Integer) && length.is_a?(Integer)
          return nil unless out.class == Numo::SFloat && data.class == Numo::SFloat && writable?(out) && contiguous1?(data)
          return nil unless ramp.nil? || (ramp.class == Numo::SFloat && contiguous1?(ramp))
          return nil if offset < 0 || length <= 0 || offset + length > out.size || length > data.size || (ramp && length > ramp.size)

          d = data[0...length]
          d = d * ramp[0...length] if ramp
          out[offset...(offset + length)] = out[offset...(offset + length)] + d
          out
        end

        def fill_range(out, from, to, value)
          return nil unless narray?(out, REAL) && writable?(out) && from.is_a?(Integer) && to.is_a?(Integer) && real_number?(value)
          return nil if from < 0 || to < from || to > out.size

          out[from...to] = value.to_f if to > from
          out
        end

        # A factor of .accumulate: nil, a number, or [SFloat, offset];
        # :bad if it can't be read.
        def factor(f, offset, length)
          return nil if f.nil?
          return f32(f) if real_number?(f)
          return :bad unless f.class == Numo::SFloat && contiguous1?(f) && offset.is_a?(Integer)
          return :bad if offset < 0 || offset + length > f.size

          f[offset...(offset + length)]
        end

        def accumulate(*args)
          raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 9)" unless args.length == 9

          out, oo, data, doff, length, a, a_off, b, b_off = args
          return nil unless [oo, doff, length].all?(Integer)
          return nil unless out.class == Numo::SFloat && data.class == Numo::SFloat && writable?(out) && contiguous1?(data)
          return nil if oo < 0 || doff < 0 || length <= 0 || oo + length > out.size || doff + length > data.size

          fa = factor(a, a_off, length)
          fb = factor(b, b_off, length)
          return nil if fa == :bad || fb == :bad

          d = data[doff...(doff + length)]
          d = d * fa if fa
          d = d * fb if fb
          out[oo...(oo + length)] = out[oo...(oo + length)] + d
          out
        end

        def last_at_least(buf, offset, length, threshold)
          return nil unless offset.is_a?(Integer) && length.is_a?(Integer) && real_number?(threshold)
          return nil unless buf.class == Numo::SFloat && contiguous1?(buf)
          return nil if offset < 0 || length < 0 || offset + length > buf.size
          return -1 if length == 0

          hits = buf[offset...(offset + length)].abs.ge(f32(threshold)).where
          hits.empty? ? -1 : hits[-1]
        end

        def copy_range(out, oo, src, so, length)
          return nil unless [oo, so, length].all?(Integer)
          return nil unless out.class == Numo::SFloat && src.class == Numo::SFloat && writable?(out) && contiguous1?(src)
          return nil if oo < 0 || so < 0 || length < 0 || oo + length > out.size || so + length > src.size

          out[oo...(oo + length)] = src[so...(so + length)] if length > 0
          out
        end
      end

      Arithmetic.singleton_methods.each do |m|
        next unless FastArithmetic.respond_to?(m)

        register m, c: FastArithmetic.method(m), ruby: Arithmetic.method(m), declines: true
      end
    end
  end
end
