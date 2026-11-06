require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Convolves its input with an impulse response (a recorded room, hall,
      # plate, spring, or cabinet; any FIR filter): the wet half of a
      # convolution reverb.  GraphNode#convolve builds it and adds the dry
      # mix.  Zero latency: the impulse's first partition runs in the time
      # domain, the rest as uniformly partitioned FFT convolution (see
      # MB::Sound::Convolution and the :convolve_engine kernel), so the
      # first output sample already holds the impulse's first tap, and the
      # output is the same at any buffer size.
      #
      # Channels: one or two inputs; an impulse of one channel (the same on
      # every input), two (mono in: left and right, mono to stereo; stereo
      # in: left to left, right to right), or four (true stereo, in the
      # order left to left, left to right, right to left, right to right; a
      # mono input feeds both sides).  Outputs: one for a mono input and
      # impulse, else two (a Channels bundle from #convolve).
      #
      # When every input has ended, the outputs ring for the impulse's
      # length and end on the exact sample where the convolution does.
      class Convolver
        include GraphNode
        include MultiOutput
        # (running state: the inputs of the last impulse length, held in the
        # engine; #carry_adopt swaps engines' state)
        node_traits memory: :long, idle_check: :sleep_ready?, carry: :adopt

        # One output of a two-output Convolver (see Convolver#outputs).
        class Output
          extend Forwardable
          include GraphNode
          include NodeOutput
          node_traits memory: :none

          def_delegators :@convolver, :sample_rate

          # The output channel index (0-based).
          attr_reader :index

          def initialize(convolver:, index:)
            @owner = convolver
            @convolver = convolver
            @index = index
          end

          def sample(count)
            @convolver.sample_internal(count, index: @index)
          end

          def sources
            { convolver: @convolver }
          end

          def to_s
            "Convolver output #{@index} of #{@convolver.outputs.length}"
          end
        end

        # Paths [input, output, impulse channel] by [inputs, impulse
        # channels].
        PATHS = {
          [1, 1] => [[0, 0, 0]],
          [2, 1] => [[0, 0, 0], [1, 1, 0]],
          [1, 2] => [[0, 0, 0], [0, 1, 1]],
          [2, 2] => [[0, 0, 0], [1, 1, 1]],
          [1, 4] => [[0, 0, 0], [0, 1, 1], [0, 0, 2], [0, 1, 3]],
          [2, 4] => [[0, 0, 0], [0, 1, 1], [1, 0, 2], [1, 1, 3]],
        }.freeze

        # Impulse samples below this fraction of the impulse's peak at its
        # end are dropped (their tail is under -120 dB).
        TRIM_FLOOR = 1e-6

        # The impulse as the engine runs it: an Array of DFloats (after
        # +gain+, normalization, +predelay+, and +length+).
        attr_reader :impulse

        # The partition size in samples (see Convolution.partition_for).
        attr_reader :partition

        # The input nodes (sampler branches).
        attr_reader :inputs

        # Output nodes: [self] for one output, else Output nodes.
        attr_reader :outputs

        attr_reader :sample_rate

        # The linear gain applied to the impulse (after normalization).
        attr_reader :gain

        # Creates a convolver of +inputs+ (an Array of one or two nodes)
        # with +impulse+: an Array of one, two, or four DFloat/SFloat
        # channels at +sample_rate+, already read (GraphNode#convolve reads
        # Samples, files, and NArrays).  +gain+ (linear) scales it after
        # +normalize+ (true: the impulse's energy per output is 1, so
        # broadband sound comes out at about its input power), +predelay+
        # (samples) delays it, and +length+ (samples, or nil for all of it)
        # truncates it with a raised-cosine fade over its last +fade+
        # samples.  +partition+ is the block size (nil: chosen for the
        # length).
        def initialize(inputs:, impulse:, sample_rate:, gain: 1.0, normalize: true, predelay: 0, length: nil, fade: nil, partition: nil)
          inputs = Array(inputs)
          raise ArgumentError, "A convolver takes one or two inputs (got #{inputs.length})" unless [1, 2].include?(inputs.length)
          inputs.each_with_index do |i, idx|
            raise ArgumentError, "Convolver input #{idx} must be a graph node (got #{i.inspect})" unless i.respond_to?(:sample)
          end
          channels = Array(impulse).map { |c| Numo::DFloat.cast(c).flatten }
          unless [1, 2, 4].include?(channels.length)
            raise ArgumentError, "An impulse has 1, 2, or 4 channels (got #{channels.length})"
          end
          raise ArgumentError, 'The impulse is empty' if channels.all? { |c| c.length == 0 }
          raise ArgumentError, 'The impulse holds a value that is not finite' unless channels.all? { |c| c.isfinite.all? }

          @sample_rate = sample_rate.to_f
          @inputs = inputs.map(&:get_sampler)
          @paths = PATHS.fetch([@inputs.length, channels.length])
          @output_count = @paths.map { |p| p[1] }.max + 1
          @gain = gain.to_f
          @impulse = shape_impulse(channels, normalize: normalize, predelay: Integer(predelay), length: length && Integer(length), fade: fade && Integer(fade))
          len = @impulse.map(&:length).max
          @partition = partition ? Integer(partition) : Convolution.partition_for(len)
          raise ArgumentError, "The partition must be a positive whole number of samples (got #{partition.inspect})" unless @partition > 0
          heads, spectra = Convolution.prepare(@impulse, @partition)
          @length = len
          @engine = Kernels.convolve_engine.new(@partition, @inputs.length, @output_count, @paths, heads, spectra, len)
          @work = Numo::DComplex.zeros(2 * @partition)

          @position = 0
          @ended = Array.new(@inputs.length, false)
          @end_position = nil
          @done = false
          @ins = Array.new(@inputs.length)
          @pads = Array.new(@inputs.length)
          @out_sets = [nil, nil]
          @set = 0
          @results = nil
          @sampled = Array.new(@output_count, false)
          @sampled_count = 0
          @node_type_name = 'Convolver'
          @outputs = @output_count == 1 ? [self].freeze : Array.new(@output_count) { |i| Output.new(convolver: self, index: i) }.freeze
        end

        def sources
          @inputs.each_with_index.to_h { |inp, i| [:"input_#{i}", inp] }
        end

        # The impulse's length in samples (after trimming).
        def impulse_length
          @length
        end

        # Silence: forgets what the inputs played (the impulse stays).
        def reset
          @engine.reset
          self
        end

        # True when everything the inputs played has rung out (the engine is
        # silent until they sound again).
        def sleep_ready?
          @engine.quiet?
        end

        # Session::Carry: same impulse layout (the state must fit).
        def carry_fits?(old)
          old.class == self.class && old.engine_shape == engine_shape
        end

        # Swaps running state with +old+ (see NodeTraits' +carry+).
        def carry_adopt(old)
          @engine.swap_state(old.carry_engine)
          NodeTraits.swap_contents(@ended, old.instance_variable_get(:@ended))
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
        end

        ADOPT_IVARS = %i[@position @end_position @done].freeze

        # For #carry_fits?: [partition, partitions, inputs, outputs,
        # impulse channels, paths].
        def engine_shape
          @engine.shape
        end

        # For #carry_adopt.
        def carry_engine
          @engine
        end

        # The next +count+ samples of a one-output convolver.
        def sample(count)
          raise 'This convolver has several outputs: sample them (#outputs)' if @output_count != 1

          r = run(count)
          r && r[0]
        end

        # For Output#sample: runs every output when one is sampled again
        # (each output once per buffer, like Reverb's outputs).
        def sample_internal(count, index:)
          if @sampled[index] || @results.nil? && @sampled_count == 0
            if @sampled[index] && @sampled_count < @output_count
              warn "Convolver output #{index} sampled again before the others"
            end
            @sampled.fill(false)
            @sampled_count = 0
            @results = run(count)
          end
          @sampled[index] = true
          @sampled_count += 1
          @results&.[](index)
        end

        def to_s
          "Convolver (#{@impulse.length} ch, #{format('%.3f', @length / @sample_rate)} s, partition #{@partition})"
        end

        private

        # Applies normalization, gain, predelay, and the length to the
        # impulse channels.
        def shape_impulse(channels, normalize:, predelay:, length:, fade:)
          raise ArgumentError, "Predelay can't be negative" if predelay < 0

          len = channels.map(&:length).max
          channels = channels.map { |c|
            c.length < len ? Numo::DFloat.zeros(len).tap { |z| z[0...c.length] = c } : c.dup
          }

          if length
            raise ArgumentError, 'The impulse length must be positive' if length <= 0
            if length < len
              channels = channels.map { |c| c[0...length].dup }
              f = (fade || length / 4).clamp(0, length)
              if f > 0
                ramp = Numo::DFloat.new(f).seq(0.5) / f # (sample centers)
                win = (Numo::NMath.cos(ramp * Math::PI) + 1) * 0.5
                channels.each { |c| c[(length - f)..] = c[(length - f)..] * win }
              end
            end
          end

          # Drop the quiet end (under -120 dB of the peak)
          peak = channels.map { |c| c.abs.max }.max
          if peak > 0
            last = channels.map { |c| (c.abs > peak * TRIM_FLOOR).where.to_a.last || 0 }.max
            channels = channels.map { |c| c[0..last].dup } if last + 1 < channels[0].length
          end

          scale = @gain
          if normalize && peak > 0
            energy = Array.new(@output_count, 0.0)
            @paths.each { |_, o, r| energy[o] += (channels[r]**2).sum }
            # (a mono input feeding a true-stereo impulse: both sides' paths
            # add coherently, but normalizing them as uncorrelated is close
            # enough for a level)
            mean = energy.sum / energy.length
            scale /= Math.sqrt(mean) if mean > 0
          end
          channels = channels.map { |c| c * scale } if scale != 1

          if predelay > 0
            channels = channels.map { |c| Numo::DFloat.zeros(predelay + c.length).tap { |z| z[predelay..] = c } }
          end
          channels
        end

        # Convolves the next +count+ samples into this buffer's output set.
        def run(count)
          return nil if @done

          n = count
          alive = false
          @inputs.each_with_index do |inp, i|
            if @ended[i]
              @ins[i] = nil
              next
            end
            buf = inp.sample(count)
            if buf.nil? || buf.empty?
              @ended[i] = true
              @end_position = [@end_position || 0, @position].max
              @ins[i] = nil
            elsif buf.length < count
              @ended[i] = true
              @end_position = [@end_position || 0, @position + buf.length].max
              pad = @pads[i]
              pad = @pads[i] = Numo::SFloat.zeros(count) unless pad && pad.length == count
              BufferHelper.zero(pad)
              pad[0...buf.length] = float_input(buf)
              @ins[i] = pad
            else
              alive = true
              @ins[i] = float_input(buf)
            end
          end

          unless alive
            # every input has ended: ring for the impulse's length
            stop = (@end_position || @position) + @length - 1
            n = [count, stop - @position].min
            if n <= 0
              @done = true
              return nil
            end
          end

          outs = output_set(count)
          Convolution.run(@engine, outs, @ins, n, @work)
          @position += n
          return outs if n == count

          @done = true if @ended.all?
          outs.map { |o| o[0...n] }
        end

        # A float32 contiguous copy of +buf+ only if it isn't one already.
        def float_input(buf)
          buf = buf.real if buf.is_a?(Numo::SComplex) || buf.is_a?(Numo::DComplex)
          buf = Numo::SFloat.cast(buf) unless buf.is_a?(Numo::SFloat)
          buf = buf.dup unless buf.contiguous?
          buf
        end

        # Alternating sets of output buffers of +count+ samples, so a Tee
        # sharing one output's last buffer keeps it while another output
        # starts the next.
        def output_set(count)
          @set ^= 1
          s = @out_sets[@set]
          s = @out_sets[@set] = Array.new(@output_count) { Numo::SFloat.zeros(count) } unless s && s[0].length == count
          s
        end
      end
    end
  end
end
