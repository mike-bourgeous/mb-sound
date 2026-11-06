require 'numo/pocketfft'

module MB
  module Sound
    # Partitioned convolution for GraphNode::Convolver (#convolve): the
    # impulse's partitions and spectra, the block boundary's transforms, and
    # the Ruby mirror of the C engine (MB::Sound::FastConvolve::Engine; the
    # :convolve_engine kernel).
    #
    # The scheme (see ext/mb/sound/fast_convolve/fast_convolve.c): the
    # impulse is cut into partitions of P samples; the first runs in the
    # time domain (a P-tap dot product per sample: no latency), the others
    # as uniformly partitioned overlap-save FFT convolution (2P-point
    # transforms once per P samples, a frequency-domain delay line of input
    # spectra).  The output is the same at any buffer size (the blocks run
    # on the node's own P-sample grid), within about -250 dB of a direct
    # convolution in double precision before the float32 output.
    module Convolution
      # Default partitions are powers of two from MIN_PARTITION to
      # MAX_PARTITION samples.
      MIN_PARTITION = 32
      MAX_PARTITION = 4096

      # The partition size (samples) that balances the head's per-sample dot
      # product (P multiply-adds) against the frequency-domain partitions
      # (about 4 L / P multiply-adds per sample, one complex product per bin
      # and partition): 2 sqrt(L) rounded to a power of two.
      def self.partition_for(length)
        return MIN_PARTITION if length <= MIN_PARTITION

        p = 2**Math.log2(2 * Math.sqrt(length)).round
        p.clamp(MIN_PARTITION, MAX_PARTITION)
      end

      # The engine's impulse data for impulse channels +irs+ (an Array of
      # 1D DFloats, all of one length) cut into partitions of +partition+
      # samples: [heads, spectra], heads a DFloat of each channel's first
      # partition reversed, spectra a DComplex of the 2P-point FFTs of
      # partitions 1... (zero-padded after the partition, scaled by 1 / 2P),
      # or nil for a single partition.
      def self.prepare(irs, partition)
        p = Integer(partition)
        len = irs.map(&:length).max
        k = [(len + p - 1) / p, 1].max
        n = 2 * p
        heads = Numo::DFloat.zeros(irs.length, p)
        spectra = k > 1 ? Numo::DComplex.zeros(irs.length, k - 1, p + 1) : nil
        seg = Numo::DFloat.zeros(n)
        irs.each_with_index do |h, c|
          h = Numo::DFloat.cast(h)
          head = Numo::DFloat.zeros(p)
          m = [h.length, p].min
          head[0...m] = h[0...m] if m > 0
          heads[c, true] = head.reverse
          (1...k).each do |part|
            seg.fill(0)
            a = part * p
            b = [a + p, h.length].min
            seg[0...(b - a)] = h[a...b] if b > a
            spectra[c, part - 1, true] = Numo::Pocketfft.rfft(seg.dup) / n
          end
        end
        [heads.reshape(irs.length * p), spectra&.reshape(irs.length * (k - 1) * (p + 1))]
      end

      # The block boundary's two transforms between +engine+'s calls (see
      # the C file), with +work+ a DComplex of 2P values.
      def self.boundary(engine, work)
        engine.fft_input(work)
        z = Numo::Pocketfft.fft(work)
        engine.spectrum(z, work)
        engine.finish(Numo::Pocketfft.fft(work))
      end

      # Convolves +n+ samples of +ins+ (an Array of SFloats or nils, one per
      # engine input, each at least +n+ long) into +outs+ (SFloats) through
      # +engine+, block by block.
      def self.run(engine, outs, ins, n, work)
        off = 0
        while off < n
          room = engine.room
          m = n - off
          m = room if room < m
          left = engine.process(outs, ins, off, m)
          boundary(engine, work) if left == 0
          off += m
        end
        outs
      end

      # The Ruby mirror of MB::Sound::FastConvolve::Engine, the same methods
      # in Numo (the :convolve_engine kernel's reference, compared within
      # KERNEL_TOLERANCE: sums run in other orders).  Slow: a few Numo calls
      # per sample.
      class RubyEngine
        def initialize(partition, inputs, outputs, paths, heads, spectra, length)
          @p = Integer(partition)
          raise ArgumentError, 'The partition must be from 1 to 2**20 samples' unless @p >= 1 && @p <= 2**20
          raise ArgumentError, 'A convolution engine takes 1 or 2 inputs and outputs' unless [1, 2].include?(inputs) && [1, 2].include?(outputs)
          raise ArgumentError, 'A convolution engine takes 1 to 64 paths' unless paths.is_a?(Array) && (1..64).cover?(paths.length)
          raise ArgumentError, 'The heads must be a DFloat' unless heads.is_a?(Numo::DFloat)
          raise ArgumentError, 'The heads must hold a whole number of partitions' unless heads.size > 0 && heads.size % @p == 0

          @n = 2 * @p
          @b = @p + 1
          @nin = inputs
          @nout = outputs
          @nir = heads.size / @p
          @heads = heads.reshape(@nir, @p).dup
          if spectra
            raise ArgumentError, 'The spectra must be a DComplex' unless spectra.is_a?(Numo::DComplex)
            per = @nir * @b
            raise ArgumentError, 'The spectra must hold (partition + 1) bins per partition and impulse' unless spectra.size > 0 && spectra.size % per == 0
            @k = 1 + spectra.size / per
            @spectra = spectra.reshape(@nir, @k - 1, @b).dup
          else
            @k = 1
            @spectra = nil
          end
          @m = @k - 1
          @length = Integer(length)
          @paths = paths.map.with_index { |t, i|
            raise ArgumentError, 'Each path is [input, output, impulse]' unless t.is_a?(Array) && t.length == 3
            a, o, r = t.map { |v| Integer(v) }
            raise ArgumentError, "Path #{i} #{t.inspect} is out of range" unless a.between?(0, @nin - 1) && o.between?(0, @nout - 1) && r.between?(0, @nir - 1)
            [a, o, r]
          }
          reset
        end

        def reset
          @seg = Numo::DFloat.zeros(@nin, @n)
          @x = Numo::DComplex.zeros(@nin, [@m, 1].max, @b)
          @acc = Numo::DComplex.zeros(@nout, @b)
          @tail = Numo::DFloat.zeros(@nout, @p)
          @pos = 0
          @block = 0
          @done = 0
          @zero_run = 0
          self
        end

        def room
          @p - @pos
        end

        def process(outs, ins, offset, n)
          raise ArgumentError, "Process #{n} samples at #{offset} with #{room} left in the block" if offset < 0 || n < 0 || n > room
          raise ArgumentError, "Expected #{@nout} outputs and #{@nin} inputs" unless outs.length == @nout && ins.length == @nin

          ins.each { |i| check_buffer(i, offset + n, 'An input') unless i.nil? }
          outs.each { |o| check_buffer(o, offset + n, 'An output'); raise FrozenError, "can't modify frozen #{o.class}" if o.frozen? }

          y = Array.new(@nout, 0.0)
          n.times do |j|
            nonzero = false
            @nin.times do |c|
              x = ins[c] ? ins[c][offset + j].to_f : 0.0
              @seg[c, @p + @pos] = x
              nonzero ||= x != 0.0
            end
            y.fill(0.0)
            @paths.each do |a, o, r|
              y[o] += (@heads[r, true] * @seg[a, (@pos + 1)..(@pos + @p)]).sum
            end
            @nout.times { |c| outs[c][offset + j] = y[c] + @tail[c, @pos] }
            @zero_run = nonzero ? 0 : @zero_run + 1
            @pos += 1
          end

          catch_up((@k - 2) * @pos / @p) if @k > 2
          shift if @pos == @p && @k == 1
          @p - @pos
        end

        def fft_input(work)
          check_boundary
          check_work(work)
          work[true] = @nin > 1 ? @seg[0, true] + @seg[1, true] * 1i : @seg[0, true]
          work
        end

        def spectrum(z, work)
          check_boundary
          check_work(work)
          catch_up(@k - 2)
          slot = @block % @m
          zk = z[0..@p]
          if @nin == 1
            @x[0, slot, true] = zk
          else
            zn = z[(@n - Numo::Int64.new(@b).seq) % @n].conj
            @x[0, slot, true] = (zk + zn) * 0.5
            @x[1, slot, true] = (zk - zn) * -0.5i
          end
          mac(1)

          zfull = @nout > 1 ? @acc[0, true] + @acc[1, true] * 1i : @acc[0, true]
          upper = @nout > 1 ? @acc[0, 1...@p].conj + @acc[1, 1...@p].conj * 1i : @acc[0, 1...@p].conj
          work[0..@p] = zfull.conj
          work[(@p + 1)..] = upper.reverse.conj
          work
        end

        def finish(y)
          check_boundary
          yp = y[@p..]
          @tail[0, true] = yp.real
          @tail[1, true] = -yp.imag if @nout > 1
          @acc.fill(0)
          shift
          self
        end

        def quiet?
          @zero_run >= @length + 2 * @n
        end

        def swap_state(other)
          raise TypeError, 'Can only swap state with another engine' unless other.is_a?(RubyEngine)
          raise ArgumentError, "Engines of different shapes can't swap state" unless other.shape[0..3] == shape[0..3]

          SWAP.each do |v|
            a = instance_variable_get(v)
            instance_variable_set(v, other.instance_variable_get(v))
            other.instance_variable_set(v, a)
          end
          self
        end

        SWAP = %i[@seg @x @acc @tail @pos @block @done @zero_run].freeze

        def shape
          [@p, @k, @nin, @nout, @nir, @paths.length]
        end

        def position
          [@pos, @block, @done]
        end

        private

        def check_buffer(b, need, name)
          unless b.is_a?(Numo::SFloat) && b.ndim == 1
            raise ArgumentError, "#{name} must be nil or a contiguous 1D SFloat"
          end
          raise ArgumentError, "#{name} is too short" if b.length < need
        end

        def check_work(w)
          raise ArgumentError, 'The work array must be a contiguous DComplex' unless w.is_a?(Numo::DComplex) && w.size == @n
          raise FrozenError, "can't modify frozen #{w.class}" if w.frozen?
        end

        def check_boundary
          raise 'Not at a block boundary with a frequency-domain part' unless @k >= 2 && @pos == @p
        end

        def catch_up(target)
          while @done < target
            mac(@done + 2)
            @done += 1
          end
        end

        def mac(k)
          slot = (@block + 1 - k) % @m
          @paths.each do |a, o, r|
            @acc[o, true] += @x[a, slot, true] * @spectra[r, k - 1, true]
          end
        end

        def shift
          @seg[true, 0...@p] = @seg[true, @p..]
          @pos = 0
          @done = 0
          @block += 1
        end
      end

      # The largest difference check mode accepts between the C engine and
      # RubyEngine (outputs are float32 near full scale; spectra and work
      # arrays grow with the partition, still far inside this).
      KERNEL_TOLERANCE = 1e-6

      Kernels.register :convolve_engine, c: MB::Sound::FastConvolve::Engine, ruby: RubyEngine, tolerance: KERNEL_TOLERANCE
    end
  end
end
