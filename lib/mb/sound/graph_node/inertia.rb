module MB
  module Sound
    module GraphNode
      # An acceleration-limited follower (the "slew" of Sonic Foundry's
      # DirectX Distortion, decoded by the Linux session's .acd study,
      # 2026-11-07): a deadbeat second-order follower whose change of
      # velocity per substep is clamped to +-rate (full-scale units), run
      # +substeps+ times per sample:
      #
      #     d = clamp((u - y) - v, -rate, rate); v += d; y += v
      #
      # Unclamped, the output lands on the input in one substep, so slow
      # and quiet signals (each sample within +-rate of the last, as the
      # first substep must stop the velocity) pass within float32 rounding
      # once running; fast, loud ones bend, or overshoot into
      # bang-bang limit cycles of a fixed amplitude (proportional to the
      # rate): "squelchy chirps".  A click of 0.5 comes out as rate * [1, 4,
      # 3] and then silence.  It is not a slope (velocity) limit: that is
      # #clip_rate.
      #
      # Substep inputs run from the first substep's input a to the sample
      # x[n] (linearly between them; with 2 substeps exactly a, then x[n]).
      # a is the previous input sample (+first+ nil, +lag+ 1: GraphNode#inertia's
      # :musical mode), or another channel's input (+first+, with +lag+ 0
      # or 1: the plug-in's interleaved-stereo quirk, :hardware mode, where
      # the left channel's first substep reads the right channel's previous
      # sample and the right's reads the left's current one).
      #
      # +rate+ is a number or a node (read per sample; 0 below 0); the
      # plug-in's slew percentage s maps to s * 0.0005 at 48 kHz.  State
      # (output, velocity, previous first-substep input) runs in double
      # precision and carries across buffers, so the output is the same at
      # any buffer size.  Kernel FastControl.inertia, mirror .process_ruby.
      class Inertia
        include GraphNode
        include SampleRateHelper
        # (a limit cycle is sound the state holds; its velocity and output
        # move to a rebuilt node: #carry_adopt)
        node_traits memory: :short, carry: :adopt

        # The rate (a Numeric or a node).
        attr_reader :rate

        # Substeps per sample.
        attr_reader :substeps

        # Follows +source+ with acceleration limit +rate+ (a number or a
        # node) over +substeps+ per sample; +first+ (a node, or nil for the
        # source itself) gives the first substep's input, +lag+ samples late
        # (0 or 1; see the class description).
        def initialize(source, rate:, substeps: 2, first: nil, lag: 1)
          @source = source.get_sampler
          @sample_rate = @source.sample_rate
          unless rate.is_a?(Numeric) || rate.respond_to?(:sample)
            raise ArgumentError, "The inertia rate must be a number or a node (got #{rate.class})"
          end
          raise ArgumentError, "The inertia rate must not be negative (got #{rate})" if rate.is_a?(Numeric) && !(rate >= 0)
          raise ArgumentError, "Substeps must be an Integer from 1 to 1024 (got #{substeps.inspect})" unless substeps.is_a?(Integer) && (1..1024).cover?(substeps)
          raise ArgumentError, "The lag must be 0 or 1 (got #{lag.inspect})" unless [0, 1].include?(lag)
          raise ArgumentError, 'A lag of 0 needs another first-substep input' if lag == 0 && first.nil?

          @rate = rate.is_a?(Numeric) ? rate.to_f : rate.get_sampler
          @substeps = substeps
          @first = first&.get_sampler
          @lag = lag
          @state = Numo::DFloat.zeros(3)
          @out = nil
          @first_buf = nil
          @node_type_name = 'inertia'
        end

        def sources
          { input: @source, rate: (@rate unless @rate.is_a?(Float)), first: @first }.compact
        end

        # Session::Carry's adoption (NodeTraits' +carry+ :adopt): true for
        # another Inertia.
        def carry_fits?(old)
          old.class == self.class
        end

        # Takes over +old+'s output, velocity, and previous input.
        def carry_adopt(old)
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
        end

        ADOPT_IVARS = %i[@state].freeze

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil?
          raise ArgumentError, 'Inertia takes real signals' if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          rate = @rate
          unless rate.is_a?(Float)
            rate = rate.sample(data.length)
            return nil if rate.nil? || rate.empty?
            data = data[0...rate.length] if rate.length < data.length
          end
          n = data.length
          data = Numo::SFloat.cast(data) unless data.is_a?(Numo::SFloat) && data.contiguous?
          @out = Numo::SFloat.zeros(n) if @out.nil? || @out.length != n
          first = @first && first_input(n)
          Kernels.inertia(data, @out, first, @lag, rate, @substeps, @state)
        end

        def to_s
          "#{super} -- inertia(#{@rate.is_a?(Float) ? @rate : 'a node'}, #{@substeps} substeps#{', interleaved' if @first})"
        end

        # The first-substep input for +n+ samples (zeros past its end).
        def first_input(n)
          f = @first.sample(n)
          return f if f.is_a?(Numo::SFloat) && f.length == n

          @first_buf = Numo::SFloat.zeros(n) if @first_buf.nil? || @first_buf.length != n
          @first_buf.fill(0)
          if f
            m = [f.length, n].min
            @first_buf[0...m] = f[0...m]
          end
          @first_buf
        end

        # GraphNode#inertia and Channels#inertia: one Inertia per channel of
        # +node+ (a node or a bundle; see GraphNode#inertia for +mode+).
        def self.build(node, rate, substeps: 2, mode: :musical)
          raise ArgumentError, "Inertia modes are :musical and :hardware (got #{mode.inspect})" unless %i[musical hardware].include?(mode)
          raise ArgumentError, ':hardware inertia runs 2 substeps (the plug-in)' if mode == :hardware && substeps != 2

          chans = node.is_a?(Channels) || (node.respond_to?(:channel_count) && node.channel_count > 1) ? node.outputs.to_a : [node]
          return Inertia.new(chans[0], rate: rate, substeps: substeps) if chans.length == 1

          nodes = chans.each_with_index.map { |c, i|
            if mode == :hardware
              # (interleaved: channel 0 reads the last channel's previous
              # sample, every other channel the one before it, now)
              Inertia.new(c, rate: rate, substeps: 2, first: chans[i - 1], lag: i == 0 ? 1 : 0)
            else
              Inertia.new(c, rate: rate, substeps: substeps)
            end
          }
          Channels.new(nodes)
        end

        # Ruby mirror of MB::Sound::FastControl.inertia (the same arguments,
        # the same operations in double precision).
        def self.process_ruby(x, out, first, lag, rate, substeps, state)
          n = x.length
          raise ArgumentError, 'The output must have as many values as the input' if out.length != n
          xs = x.to_a
          fs = first&.to_a
          rs = rate.is_a?(Numo::NArray) ? Numo::SFloat.cast(rate).to_a : nil
          r0 = rs ? nil : rate.to_f
          y, v, prev = state.to_a
          last = (substeps - 1).to_f
          ys = Array.new(n)
          n.times do |i|
            xn = xs[i]
            src = fs ? fs[i] : xn
            a = lag == 1 ? prev : src
            prev = src
            aa = rs ? rs[i] : r0
            aa = 0.0 unless aa > 0
            substeps.times do |k|
              u = k == substeps - 1 ? xn : (k == 0 ? a : a + (xn - a) * k.to_f / last)
              d = (u - y) - v
              if d > aa
                d = aa
              elsif d < -aa
                d = -aa
              end
              v += d
              y += v
            end
            ys[i] = y
          end
          state[0] = y
          state[1] = v
          state[2] = prev
          out[0..] = Numo::SFloat.cast(ys) if n > 0
          out
        end
      end

      Kernels.register :inertia, c: FastControl.method(:inertia), ruby: Inertia.method(:process_ruby),
        about: 'the acceleration-limited follower (GraphNode::Inertia, the DirectX Distortion slew)'
    end
  end
end
