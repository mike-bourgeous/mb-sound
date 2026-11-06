require 'numo/pocketfft'

module MB
  module Sound
    # Partitioned convolution for GraphNode::Convolver (#convolve): the
    # partition plan, the impulse's spectra, the block loop with its
    # transforms (Runner), and the Ruby mirror of the C engine
    # (MB::Sound::FastConvolve::Engine; the :convolve_engine kernel).
    #
    # The scheme (ext/mb/sound/fast_convolve/fast_convolve.c): the impulse's
    # first HEAD samples run in the time domain (a dot product per sample:
    # no latency); the rest in levels of overlap-save FFT convolution, each
    # with a block size and a frequency-domain delay line of input spectra
    # (non-uniform partitioning, Gardner 1995): by default partitions of 128
    # samples to 1024, of 1024 to 16384, and of 8192 from 16384 to the end.
    # The last level starts a block later than its size requires, so all its
    # work for a block (two 16384-point transforms built from sub-FFTs, the
    # partitions) is spread over the previous block's buffers as small tasks
    # instead of landing in one.  The output is the same at any buffer size.
    module Convolution
      # The default plan's head and its levels: [block, k0, stop]; each
      # level's partitions start at k0 * block, its last ending at +stop+ or
      # the impulse's end (nil).
      HEAD = 128
      LEVELS = [[128, 1, 1024], [1024, 1, 16_384], [8192, 2, nil]].freeze

      # A partition plan: +head+ taps in the time domain, then +levels+ as
      # [block, k0, partitions].
      Plan = Data.define(:head, :levels) do
        def to_s
          ([head.to_s] + levels.map { |q, k0, k| "#{k} x #{q}#{k0 == 2 ? ' (spread)' : ''}" }).join(' + ')
        end
      end

      # The partition plan for an impulse of +length+ samples: the default
      # (HEAD and LEVELS) or, with +partition+, a uniform one (a head of
      # +partition+ taps and blocks of +partition+ samples, every boundary's
      # transforms in one buffer).
      def self.plan(length, partition: nil)
        if partition
          p = Integer(partition)
          raise ArgumentError, "The partition must be a positive whole number of samples (got #{partition.inspect})" unless p > 0
          k = length > p ? (length - p + p - 1) / p : 0
          return Plan.new(head: p, levels: k > 0 ? [[p, 1, k]] : [])
        end

        levels = []
        LEVELS.each do |q, k0, stop|
          start = k0 * q
          break if length <= start
          stop = [stop || length, length].min
          levels << [q, k0, (stop - start + q - 1) / q]
        end
        Plan.new(head: HEAD, levels: levels)
      end

      # The engine's impulse data for impulse channels +irs+ (1D DFloats)
      # under +plan+: [head, levels], head a DFloat of each channel's first
      # head taps reversed, levels an Array of [block, k0, spectra] (the
      # 2 * block-point FFTs of each partition zero-padded after it, scaled
      # by 1 / (2 * block)).
      def self.prepare(irs, plan)
        d = plan.head
        head = Numo::DFloat.zeros(irs.length, d)
        irs.each_with_index do |h, c|
          h = Numo::DFloat.cast(h)
          m = [h.length, d].min
          row = Numo::DFloat.zeros(d)
          row[0...m] = h[0...m] if m > 0
          head[c, true] = row.reverse
        end
        levels = plan.levels.map { |q, k0, k|
          n = 2 * q
          spectra = Numo::DComplex.zeros(irs.length, k, q + 1)
          seg = Numo::DFloat.zeros(n)
          irs.each_with_index do |h, c|
            h = Numo::DFloat.cast(h)
            k.times do |j|
              a = (k0 + j) * q
              b = [a + q, h.length].min
              seg.fill(0)
              seg[0...(b - a)] = h[a...b] if b > a
              spectra[c, j, true] = Numo::Pocketfft.rfft(seg.dup) / n
            end
          end
          [q, k0, spectra.reshape(irs.length * k * (q + 1))]
        }
        [head.reshape(irs.length * d), levels]
      end

      # Runs an engine block by block with its transforms: the work arrays
      # for each level's boundary and the spread level's sub-FFTs.
      class Runner
        # The engine (FastConvolve::Engine or RubyEngine, from Kernels).
        attr_reader :engine

        # The partition plan.
        attr_reader :plan

        # An engine for impulse channels +irs+ (DFloats), +inputs+ and
        # +outputs+ (1 or 2), and +paths+ ([input, output, impulse] triples),
        # partitioned by +plan+ (default Convolution.plan with +partition+).
        # +kernel+ is the engine class (specs compare the C engine with the
        # mirror).
        def initialize(irs, inputs:, outputs:, paths:, partition: nil, plan: nil, kernel: Kernels.convolve_engine)
          len = irs.map(&:length).max
          @plan = plan || Convolution.plan(len, partition: partition)
          head, levels = Convolution.prepare(irs, @plan)
          @engine = kernel.new(@plan.head, inputs, outputs, paths, head, levels, len)
          @works = @plan.levels.map { |q, _, _| Numo::DComplex.zeros(2 * q) }
          m = @engine.sub_size
          @sub = m > 0 ? Numo::DComplex.zeros(m) : nil
        end

        # Convolves +n+ samples of +ins+ (an Array of SFloats or nils, one
        # per input, each at least +n+ long) into +outs+ (SFloats).
        def run(outs, ins, n)
          e = @engine
          off = 0
          while off < n
            m = e.room
            m = n - off if n - off < m
            left = e.process(outs, ins, off, m)
            boundaries(e.boundary_levels) if left == 0
            Convolution.fft_into(@sub, e) while @sub && e.task(@sub) == 1
            off += m
          end
          outs
        end

        private

        # The two transforms of each uniform level in +mask+.
        def boundaries(mask)
          i = 0
          while mask > 0
            if mask & 1 == 1
              w = @works[i]
              @engine.fft_input(i, w)
              @engine.spectrum(i, Numo::Pocketfft.fft(w), w)
              @engine.finish(i, Numo::Pocketfft.fft(w))
            end
            mask >>= 1
            i += 1
          end
        end
      end

      # Hands +engine+ the FFT of +sub+ (the spread level's sub-FFT input).
      def self.fft_into(sub, engine)
        engine.task_result(Numo::Pocketfft.fft(sub))
      end

      # The Ruby mirror of MB::Sound::FastConvolve::Engine: the same methods
      # and the same tasks in the same order (see the C file), in Numo (the
      # :convolve_engine kernel's reference, compared within
      # KERNEL_TOLERANCE: sums run in other orders).  Slow: Numo calls per
      # sample.
      class RubyEngine
        # A level's state (see the C file's struct conv_level).
        Level = Struct.new(:q, :n, :b, :k0, :k, :spread, :h, :seg, :x, :acc, :tail, :pos, :block, :done,
                           :tail_next, :pending, :fa, :fb, :wtab, :r, :m, :stages, :tasks, :tp, :total_weight, :weight_done, :sub_waiting)

        def initialize(head_taps, inputs, outputs, paths, head, levels, length)
          @d = Integer(head_taps)
          raise ArgumentError, 'The head must be 1 to 2**20 taps' unless @d >= 1 && @d <= 2**20
          raise ArgumentError, 'A convolution engine takes 1 or 2 inputs and outputs' unless [1, 2].include?(inputs) && [1, 2].include?(outputs)
          raise ArgumentError, 'A convolution engine takes 1 to 64 paths' unless paths.is_a?(Array) && (1..64).cover?(paths.length)
          raise ArgumentError, 'The head must be a DFloat' unless head.is_a?(Numo::DFloat)
          raise ArgumentError, 'The head must hold head_taps values per impulse' unless head.size > 0 && head.size % @d == 0
          raise ArgumentError, 'At most 8 levels' if levels.length > 8

          @nin = inputs
          @nout = outputs
          @nir = head.size / @d
          @head = head.reshape(@nir, @d).dup
          @length = Integer(length)
          @paths = paths.map.with_index { |t, i|
            raise ArgumentError, 'Each path is [input, output, impulse]' unless t.is_a?(Array) && t.length == 3
            a, o, r = t.map { |v| Integer(v) }
            raise ArgumentError, "Path #{i} #{t.inspect} is out of range" unless a.between?(0, @nin - 1) && o.between?(0, @nout - 1) && r.between?(0, @nir - 1)
            [a, o, r]
          }
          qmax = @d
          @levels = levels.map.with_index { |(q, k0, spectra), i|
            raise ArgumentError, "Level #{i}'s block must be a multiple of the head taps" unless q.is_a?(Integer) && q >= 1 && q % @d == 0
            raise ArgumentError, "Level #{i}'s k0 must be 1 or 2" unless [1, 2].include?(k0)
            if k0 == 2 && (i != levels.length - 1 || q < 512 || (q & (q - 1)) != 0)
              raise ArgumentError, 'Only the last level may be spread (k0 2), with a power-of-two block of at least 512'
            end
            raise ArgumentError, "Level #{i}'s spectra must be a DComplex" unless spectra.is_a?(Numo::DComplex)
            per = @nir * (q + 1)
            raise ArgumentError, "Level #{i}'s spectra must hold (block + 1) bins per partition and impulse" unless spectra.size > 0 && spectra.size % per == 0

            k = spectra.size / per
            l = Level.new(q, 2 * q, q + 1, k0, k, k0 == 2, spectra.reshape(@nir, k, q + 1).dup)
            if l.spread
              ang = Numo::DFloat.new(l.n / 2).seq * (-2.0 * Math::PI / l.n)
              l.wtab = Numo::NMath.cos(ang) + Numo::NMath.sin(ang) * 1i
              r = 8
              r /= 2 while r > 1 && l.n / r < 1024
              l.r = r
              l.m = l.n / r
              l.stages = Math.log2(r).round
              l.tasks = tasks_for(l)
              l.total_weight = l.tasks.sum { |t| t[4] }
            end
            qmax = [(k0 + 1) * q, qmax].max
            l
          }
          @quiet_after = @length + 2 * qmax + @d
          reset
        end

        def reset
          @hist = Numo::DFloat.zeros(@nin, 2 * @d)
          @hpos = 0
          @zero_run = 0
          @levels.each do |l|
            l.seg = Numo::DFloat.zeros(@nin, l.n)
            l.x = Numo::DComplex.zeros(@nin, l.k, l.b)
            l.acc = Numo::DComplex.zeros(@nout, l.b)
            l.tail = Numo::DFloat.zeros(@nout, l.q)
            l.pos = 0
            l.block = 0
            l.done = 0
            next unless l.spread

            l.tail_next = Numo::DFloat.zeros(@nout, l.q)
            l.pending = Numo::DFloat.zeros(@nin, l.n)
            l.fa = Numo::DComplex.zeros(l.n)
            l.fb = Numo::DComplex.zeros(l.n)
            l.tp = 0
            l.weight_done = 0
            l.sub_waiting = false
          end
          self
        end

        def room
          ([@d - @hpos] + @levels.map { |l| l.q - l.pos }).min
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
              @hist[c, @d + @hpos] = x
              @levels.each { |l| l.seg[c, l.q + l.pos] = x }
              nonzero ||= x != 0.0
            end
            y.fill(0.0)
            @paths.each do |a, o, r|
              y[o] += (@head[r, true] * @hist[a, (@hpos + 1)..(@hpos + @d)]).sum
            end
            @levels.each do |l|
              @nout.times { |c| y[c] += l.tail[c, l.pos] }
              l.pos += 1
            end
            @nout.times { |c| outs[c][offset + j] = y[c] }
            @zero_run = nonzero ? 0 : @zero_run + 1
            @hpos += 1
            if @hpos == @d
              @hist[true, 0...@d] = @hist[true, @d..]
              @hpos = 0
            end
          end
          @levels.each { |l| catch_up(l, (l.k - 1) * l.pos / l.q) if !l.spread && l.k > 1 }
          room
        end

        def boundary_levels
          mask = 0
          @levels.each_with_index { |l, i| mask |= 1 << i if !l.spread && l.pos == l.q }
          mask
        end

        def fft_input(level, work)
          l = uniform_at_boundary(level)
          check_work(work, l.n)
          work[true] = @nin > 1 ? l.seg[0, true] + l.seg[1, true] * 1i : l.seg[0, true]
          work
        end

        def spectrum(level, z, work)
          l = uniform_at_boundary(level)
          check_work(work, l.n)
          catch_up(l, l.k - 1)
          unpack(l, z, l.block % l.k)
          mac(l, 0, l.block)
          pack(l, work)
          work
        end

        def finish(level, y)
          l = uniform_at_boundary(level)
          store(l, y, l.tail)
          l.acc.fill(0)
          shift(l)
          self
        end

        def task(sub)
          l = spread_level
          return 0 unless l
          raise 'A sub-FFT result is due first (task_result)' if l.sub_waiting

          target = l.total_weight.to_f * l.pos / l.q
          while l.tp < l.tasks.length && l.weight_done < target
            kind, a, b, c, w = l.tasks[l.tp]
            case kind
            when :sub_f
              check_work(sub, l.m)
              idx = Numo::Int64.new(l.m).seq * l.r + a
              sub[true] = @nin > 1 ? l.pending[0, idx] + l.pending[1, idx] * 1i : l.pending[0, idx]
              l.sub_waiting = true
              return 1
            when :sub_i
              check_work(sub, l.m)
              sub[true] = l.fb[Numo::Int64.new(l.m).seq * l.r + a]
              l.sub_waiting = true
              return 1
            when :combine_f, :combine_i then combine(l, a, b, c)
            when :unpack then unpack(l, result(l), (l.block - 1) % l.k)
            when :mac then mac(l, a, l.block - 1 - a)
            when :pack
              pack(l, l.fb)
              l.acc.fill(0)
            when :store then store(l, result(l), l.tail_next)
            end
            l.weight_done += w
            l.tp += 1
          end

          if l.pos == l.q
            raise "The spread level's tasks didn't finish by its block boundary" if l.tp < l.tasks.length

            l.tail, l.tail_next = l.tail_next, l.tail
            l.pending = l.seg.dup
            shift(l)
            l.tp = 0
            l.weight_done = 0
          end
          0
        end

        def task_result(z)
          l = spread_level
          raise 'No sub-FFT is waiting for its result' unless l&.sub_waiting

          a = l.tasks[l.tp][1]
          l.fa[(a * l.m)...((a + 1) * l.m)] = z
          l.sub_waiting = false
          l.weight_done += l.tasks[l.tp][4]
          l.tp += 1
          self
        end

        def sub_size
          spread_level&.m || 0
        end

        def quiet?
          @zero_run >= @quiet_after
        end

        def swap_state(other)
          raise TypeError, 'Can only swap state with another engine' unless other.is_a?(RubyEngine)
          raise ArgumentError, "Engines of different shapes can't swap state" unless other.shape.values_at(0, 1, 2, 5) == shape.values_at(0, 1, 2, 5)

          %i[@hist @hpos @zero_run].each do |v|
            a = instance_variable_get(v)
            instance_variable_set(v, other.instance_variable_get(v))
            other.instance_variable_set(v, a)
          end
          @levels.zip(other.engine_levels).each do |x, y|
            %i[seg x acc tail pos block done tail_next pending fa fb tp weight_done].each do |f|
              x[f], y[f] = y[f], x[f]
            end
          end
          self
        end

        def shape
          [@d, @nin, @nout, @nir, @paths.length, @levels.map { |l| [l.q, l.k0, l.k] }]
        end

        def position
          [@hpos, @levels.map { |l| [l.pos, l.block, l.spread ? l.tp : l.done] }]
        end

        # For #swap_state.
        def engine_levels
          @levels
        end

        private

        # The spread level's tasks (as the C engine's level_tasks): [kind,
        # a, b, c, weight].
        def tasks_for(l)
          half = l.n / 2
          chunk = 2048
          t = []
          2.times do |phase|
            l.r.times { |i| t << [phase == 0 ? :sub_f : :sub_i, i, 0, 0, 4 * l.m] }
            l.stages.times do |s|
              (0...half).step(chunk) { |b| c = [b + chunk, half].min; t << [phase == 0 ? :combine_f : :combine_i, s, b, c, c - b] }
            end
            if phase == 0
              t << [:unpack, 0, 0, 0, l.b]
              l.k.times { |j| t << [:mac, j, 0, 0, l.b * @paths.length] }
              t << [:pack, 0, 0, 0, l.n / 2]
            else
              t << [:store, 0, 0, 0, l.q / 2]
            end
          end
          t
        end

        def check_buffer(b, need, name)
          raise ArgumentError, "#{name} must be nil or a contiguous 1D SFloat" unless b.is_a?(Numo::SFloat) && b.ndim == 1
          raise ArgumentError, "#{name} is too short" if b.length < need
        end

        def check_work(w, size)
          raise ArgumentError, 'The work array must be a contiguous DComplex' unless w.is_a?(Numo::DComplex) && w.size == size
          raise FrozenError, "can't modify frozen #{w.class}" if w.frozen?
        end

        def uniform_at_boundary(level)
          l = @levels[Integer(level)]
          raise "Level #{level} is not a uniform level at its block boundary" unless l && !l.spread && l.pos == l.q
          l
        end

        def spread_level
          l = @levels.last
          l&.spread ? l : nil
        end

        def catch_up(l, target)
          while l.done < target
            j = l.done + 1
            mac(l, j, l.block - j)
            l.done += 1
          end
        end

        def mac(l, j, spectrum_block)
          slot = spectrum_block % l.k
          @paths.each { |a, o, r| l.acc[o, true] += l.x[a, slot, true] * l.h[r, j, true] }
        end

        def unpack(l, z, slot)
          zk = z[0..l.q]
          if @nin == 1
            l.x[0, slot, true] = zk
          else
            zn = z[(l.n - Numo::Int64.new(l.b).seq) % l.n].conj
            l.x[0, slot, true] = (zk + zn) * 0.5
            l.x[1, slot, true] = (zk - zn) * -0.5i
          end
        end

        def pack(l, work)
          a = l.acc
          zfull = @nout > 1 ? a[0, true] + a[1, true] * 1i : a[0, true]
          upper = @nout > 1 ? a[0, 1...l.q].conj + a[1, 1...l.q].conj * 1i : a[0, 1...l.q].conj
          work[0..l.q] = zfull.conj
          work[(l.q + 1)..] = upper.reverse.conj
        end

        def store(l, y, tail)
          yp = y[l.q..]
          tail[0, true] = yp.real
          tail[1, true] = -yp.imag if @nout > 1
        end

        def combine(l, s, b0, b1)
          src, dst = s.even? ? [l.fa, l.fb] : [l.fb, l.fa]
          m = l.m << s
          rc = l.n / m
          step = l.n / (2 * m)
          b = Numo::Int64.new(b1 - b0).seq + b0
          i = b / m
          k = b % m
          av = src[i * m + k]
          bv = src[(i + rc / 2) * m + k]
          t = l.wtab[k * step] * bv
          o = i * 2 * m + k
          dst[o] = av + t
          dst[o + m] = av - t
        end

        def result(l)
          l.stages.even? ? l.fa : l.fb
        end

        def shift(l)
          l.seg[true, 0...l.q] = l.seg[true, l.q..]
          l.pos = 0
          l.done = 0
          l.block += 1
        end
      end

      # The largest difference check mode accepts between the C engine and
      # RubyEngine (outputs are float32 near full scale; spectra and work
      # arrays grow with the block size, still far inside this).
      KERNEL_TOLERANCE = 1e-6

      Kernels.register :convolve_engine, c: MB::Sound::FastConvolve::Engine, ruby: RubyEngine, tolerance: KERNEL_TOLERANCE
    end
  end
end
