module MB
  module Sound
    module Kernels
      # The Ruby mirrors of MB::FastSound's buffer functions (kernels-1):
      # number_to_freq, matrix_mix, the logarithms, and the smoothstep
      # fills, with the C functions' in-place rules (an inplace contiguous
      # buffer of the kernel's type is written where it is, anything else is
      # copied first).  fast_sound is built without -ffp-contract=off, so the
      # float products and sums here match the C build that doesn't fuse
      # them (GCC's -std=c99); the logarithms are libm's float functions in
      # C, Numo's in Ruby, compared within a tolerance.
      module Buffers
        module_function

        # The buffer a FastSound kernel writes: +narray+ cast to +type+,
        # copied unless it was an inplace contiguous one.  Returns [buffer,
        # was_inplace].
        def writable(narray, type)
          raise ArgumentError, "Only 1D NArrays may be processed (got #{narray.ndim} dimensions)" unless narray.ndim == 1

          inplace = narray.inplace?
          buf = type.cast(narray)
          return [buf, true] if inplace && buf.contiguous? && buf.equal?(narray)

          buf = buf.dup if buf.equal?(narray) || !buf.contiguous?
          [buf, false]
        end

        # The mirror of FastSound.number_to_freq: a Numeric's frequency, or
        # an SFloat of frequencies (the plan layer's 2^x at MB::Sound.precision
        # :fast, libm's pow at :exact).
        def number_to_freq(number, tune_note, tune_freq)
          tnum = tune_note.to_f
          tfrq = tune_freq.to_f
          return tfrq * 2.0**((number.to_f - tnum) / 12.0) if number.is_a?(Numeric)

          buf, = writable(number, Numo::SFloat)
          if MB::FastSound.fast_math?
            buf[true] = Plan::VecExp2.note_freq(buf, tnum, tfrq)
          else
            buf[true] = buf.to_a.map { |v| tfrq * 2.0**((v - tnum) / 12.0) }
          end
          buf.not_inplace!
        end

        # The mirror of FastSound.matrix_mix: outputs[i] = sum of
        # matrix[i, j] * inputs[j] in float, skipping zeros and adding or
        # subtracting for +-1.
        def matrix_mix(matrix, inputs, outputs)
          raise TypeError, 'Inputs must be an Array' unless inputs.is_a?(Array)
          raise TypeError, 'Outputs must be an Array' unless outputs.is_a?(Array)
          raise ArgumentError, 'The matrix must be a contiguous 2D DFloat' unless matrix.class == Numo::DFloat && matrix.ndim == 2 && matrix.contiguous?

          rows, cols = matrix.shape
          raise ArgumentError, "Expected #{cols} inputs for the matrix, got #{inputs.length}" unless inputs.length == cols
          raise ArgumentError, "Expected #{rows} outputs for the matrix, got #{outputs.length}" unless outputs.length == rows
          return outputs if rows == 0 || cols == 0

          count = outputs[0].shape[0]
          inputs.each_with_index { |x, j| check_mix_buffer(x, count, 'Input', j) }
          outputs.each_with_index do |o, i|
            raise ArgumentError, "Output #{i} has a different length than output 0" unless o.shape[0] == count

            check_mix_buffer(o, count, 'Output', i)
            raise ArgumentError, "Output #{i} is also input #{inputs.index { |x| x.equal?(o) }}" if inputs.any? { |x| x.equal?(o) }

            acc = Numo::SFloat.zeros(count)
            cols.times do |j|
              c = matrix[i, j]
              x = inputs[j][0...count]
              next if c == 0

              acc = if c == 1 then acc + x
                    elsif c == -1 then acc - x
                    else acc + x * c
                    end
            end
            o[true] = acc
          end
          outputs
        end

        def check_mix_buffer(v, count, name, idx)
          unless v.class == Numo::SFloat && v.ndim == 1 && v.contiguous?
            raise ArgumentError, "#{name} #{idx} must be a contiguous 1D SFloat"
          end
          raise ArgumentError, "#{name} #{idx} is shorter than the outputs (#{v.shape[0]} < #{count})" if v.shape[0] < count
        end

        LOG_TYPES = [Numo::SFloat, Numo::DFloat, Numo::SComplex, Numo::DComplex].freeze

        # The logarithm mirrors: FastSound.narray_log/log2/log10 keep SFloat,
        # DFloat, SComplex, and DComplex (others become DFloat).
        def narray_log(narray)
          log_of(narray) { |b| Numo::NMath.log(b) }
        end

        def narray_log2(narray)
          log_of(narray) { |b| complex?(b) ? Numo::NMath.log(b) / Math.log(2) : Numo::NMath.log2(b) }
        end

        def narray_log10(narray)
          log_of(narray) { |b| complex?(b) ? Numo::NMath.log(b) / Math.log(10) : Numo::NMath.log10(b) }
        end

        def complex?(b)
          b.is_a?(Numo::SComplex) || b.is_a?(Numo::DComplex)
        end

        def log_of(narray)
          narray = Numo::DFloat.cast(narray) unless LOG_TYPES.include?(narray.class)
          inplace = narray.inplace? && narray.contiguous?
          buf = inplace ? narray : narray.dup
          buf[true] = yield(buf.dup)
          inplace ? buf : buf.not_inplace!
        end

        # The smoothstep fills: +narray+ (or a copy, see .writable; SComplex
        # stays complex) filled with the curve at (i + 0.5) / length.
        def smoothstep_buf(narray)
          fill_with(narray) { |x| 3 * x * x - 2 * x * x * x }
        end

        def smootherstep_buf(narray)
          fill_with(narray) { |x| 6 * x * x * x * x * x - 15 * x * x * x * x + 10 * x * x * x }
        end

        def fill_with(narray)
          type = narray.is_a?(Numo::SComplex) || narray.is_a?(Numo::DComplex) ? Numo::SComplex : Numo::SFloat
          buf, = writable(narray, type)
          n = buf.shape[0]
          buf[true] = Array.new(n) { |i| yield((i + 0.5) / n.to_f) } if n > 0
          buf
        end
      end

      register :number_to_freq, c: MB::FastSound.method(:number_to_freq), ruby: Buffers.method(:number_to_freq)
      register :matrix_mix, c: MB::FastSound.method(:matrix_mix), ruby: Buffers.method(:matrix_mix)
      register :narray_log, c: MB::FastSound.method(:narray_log), ruby: Buffers.method(:narray_log), tolerance: 1e-5
      register :narray_log2, c: MB::FastSound.method(:narray_log2), ruby: Buffers.method(:narray_log2), tolerance: 1e-5
      register :narray_log10, c: MB::FastSound.method(:narray_log10), ruby: Buffers.method(:narray_log10), tolerance: 1e-5
      # The complex synthesis integrals kept aside from the live paths
      # (omnibus18: FastSound::ComplexSynthesis; mb-math's Ruby versions,
      # which Tone's Ruby mirror uses; complex_synthesis_spec compares them
      # within 1e-12: different libm and table paths)
      %i[csc_int csc_int_int cot_int].each do |f|
        register f, c: MB::FastSound::ComplexSynthesis.method(f), ruby: MB::M.method(f), tolerance: 1e-12
      end
      register :smoothstep_buf, c: MB::FastSound.method(:smoothstep_buf), ruby: Buffers.method(:smoothstep_buf)
      register :smootherstep_buf, c: MB::FastSound.method(:smootherstep_buf), ruby: Buffers.method(:smootherstep_buf)
    end
  end
end
