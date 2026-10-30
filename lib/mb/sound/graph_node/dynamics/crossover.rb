module MB
  module Sound
    module GraphNode
      class Dynamics
        # Splits one channel into frequency bands with Linkwitz-Riley
        # crossovers whose bands add back up to an allpass (flat magnitude,
        # the phase of the matching allpass cascade).  LR2, LR4 (default),
        # or LR8 (+order+ 2, 4, 8: 12, 24, 48 dB/octave), built from TPT
        # state-variable filters (exact bilinear-transform responses, so the
        # sum is flat to rounding; stable for any cutoff below Nyquist).
        #
        # A tree: the first crossover splits the input into its lowpass
        # (band 0) and highpass, the next splits that highpass, and so on;
        # each lower band also passes through the allpasses of the higher
        # crossovers so every band has the same phase.  LR2's high bands are
        # inverted (its low + high is an allpass only that way).
        #
        # The bands are this bundle's outputs, low to high.  Kernel
        # MB::Sound::FastDynamics.crossover, exact Ruby mirror
        # .process_ruby.  Built by DynamicsMethods#bands.
        class Crossover < Channels
          node_traits memory: :short

          # Crossover op kinds (as in the kernel).
          SPLIT = 0
          LOW = 1
          HIGH = 2
          ALLPASS = 3
          LOW_MINUS_HIGH = 4

          # Butterworth section damping (k = 1/Q) per Linkwitz-Riley order.
          ORDERS = {
            2 => [2.0],
            4 => [Math.sqrt(2)],
            8 => [2 * Math.cos(Math::PI / 8), 2 * Math.cos(3 * Math::PI / 8)],
          }.freeze

          # Filter states this small are flushed to zero.
          FLUSH = 1e-30

          # One band output.
          class Band
            include GraphNode
            include GraphNode::NodeOutput
            node_traits memory: :none

            # The band index (0 lowest).
            attr_reader :index

            def initialize(owner:, index:)
              @owner = owner
              @index = index
              @node_type_name = 'Band'
            end

            def sample(count)
              @owner.sample_internal(count, @index)
            end

            def sample_rate
              @owner.sample_rate
            end

            def sample_rate=(rate)
              @owner.sample_rate = rate
              self
            end

            def sources
              { input: @owner.input }
            end

            # Plan layer: a boundary (see #plan_unsupported_reason).
            include Plan::Describable

            def plan_unsupported_reason
              'a crossover band (one filter bank computes every band together)'
            end

            def to_s
              lo, hi = @owner.band_edges(@index)
              "Band #{@index + 1} (#{lo ? "#{MB::M.sigfigs(lo, 3)} Hz" : '0'}..#{hi ? "#{MB::M.sigfigs(hi, 3)} Hz" : 'Nyquist'})"
            end
          end

          # The input node (a sampler branch).
          attr_reader :input

          # Crossover frequencies (Hz), low to high.
          attr_reader :frequencies

          # The Linkwitz-Riley order.
          attr_reader :order

          attr_reader :sample_rate

          # Splits +input+ (one channel) at +frequencies+ (Hz numbers or
          # Pitches, increasing).
          def initialize(input, frequencies, order: 4)
            raise ArgumentError, "Crossover input must be a graph node (got #{input.class})" unless input.respond_to?(:sample)
            raise ArgumentError, "Linkwitz-Riley order must be one of #{ORDERS.keys.join(', ')} (got #{order.inspect})" unless ORDERS.include?(order)
            freqs = frequencies.map { |f| f.is_a?(MB::Sound::Pitch) ? f.oscillator_frequency.to_f : f }
            unless !freqs.empty? && freqs.all? { |f| f.is_a?(Numeric) && f > 0 }
              raise ArgumentError, "Crossover frequencies must be positive numbers or Pitches (got #{frequencies.inspect})"
            end
            raise ArgumentError, 'Crossover frequencies must increase' unless freqs.each_cons(2).all? { |a, b| a < b }

            @input = input.get_sampler
            @frequencies = freqs.map(&:to_f).freeze
            @order = order
            @sample_rate = @input.sample_rate.to_f
            @sampled = Array.new(@frequencies.length + 1, false)
            @frame = nil
            @buffer_sets = nil # (Dynamics::Framed.next_buffers)
            @buffer_index = nil
            build

            super(Array.new(@frequencies.length + 1) { |i| Band.new(owner: self, index: i) })
          end

          # The lower and upper crossover frequencies of band +index+ (nil
          # for 0 Hz and Nyquist).
          def band_edges(index)
            [index > 0 ? @frequencies[index - 1] : nil, @frequencies[index]]
          end

          # Changes the sample rate (recomputing the filters; states kept).
          def sample_rate=(rate)
            @input.sample_rate = rate
            @sample_rate = rate.to_f
            build(keep_state: true)
          end
          alias at_rate sample_rate=

          # Clears the filter states.
          def reset
            @state.fill(0)
            self
          end

          def to_s
            "LR#{@order} crossover at #{@frequencies.map { |f| "#{MB::M.sigfigs(f, 4)} Hz" }.join(', ')}"
          end

          def to_s_graphviz
            "#{graph_node_name || 'Crossover'}\nLR#{@order} #{@frequencies.map { |f| MB::M.sigfigs(f, 4) }.join(', ')} Hz"
          end

          # Called by the bands: splits a new frame when band +index+ comes
          # back for one.
          def sample_internal(count, index)
            if @sampled[index] || @frame.nil?
              if @sampled.any? && !@sampled.all?
                warn "#{self.class.name} band #{index} sampled again before the other bands"
              end
              @sampled.fill(false)
              data = @input.sample(count)
              if data.nil? || data.empty?
                @frame = :ended
              else
                n = data.length
                outs = Dynamics::Framed.next_buffers(self, @frequencies.length + 1, n)
                MB::Sound::FastDynamics.crossover(outs, data, @program, @band_regs, @state, @registers)
                @frame = outs
              end
            end
            @sampled[index] = true
            @frame == :ended ? nil : @frame[index]
          end

          # The kernel program (a DFloat of rows), band registers, and
          # register count, for specs.
          def program
            [@program, @band_regs, @registers]
          end

          # The exact Ruby mirror of FastDynamics.crossover.
          def self.process_ruby(outs, input, program, bands, state, registers)
            n = outs[0].length
            rows = program.to_a.each_slice(9).to_a
            x = Dynamics.signal_values(input, n)
            reg = Array.new(registers, 0.0)
            n.times do |i|
              reg[0] = x.is_a?(Array) ? x[i] : x
              rows.each_with_index do |row, r|
                src, d1, d2, kind, a1, a2, a3, k, sign = row
                s0 = state[r * 2]
                s1 = state[r * 2 + 1]
                v0 = reg[src.to_i]
                v3 = v0 - s1
                v1 = a1 * s0 + a2 * v3
                v2 = s1 + a2 * s0 + a3 * v3
                s0 = 2.0 * v1 - s0
                s1 = 2.0 * v2 - s1
                s0 = 0.0 if s0.abs < FLUSH
                s1 = 0.0 if s1.abs < FLUSH
                state[r * 2] = s0
                state[r * 2 + 1] = s1
                lp = v2
                hp = v0 - k * v1 - v2
                case kind.to_i
                when SPLIT
                  reg[d1.to_i] = lp
                  reg[d2.to_i] = hp * sign
                when LOW then reg[d1.to_i] = lp
                when HIGH then reg[d1.to_i] = hp * sign
                when ALLPASS then reg[d1.to_i] = v0 - 2.0 * k * v1
                else reg[d1.to_i] = lp - hp
                end
              end
              bands.each_with_index { |b, idx| outs[idx][i] = reg[b] }
            end
            outs
          end

          private

          # Builds the SVF program: for each crossover, a split of the
          # current "rest" register into low and high chains, then allpasses
          # on every lower band.
          def build(keep_state: false)
            rows = []
            next_reg = 1
            rest = 0
            band_regs = []
            ks = ORDERS[@order]
            sign = @order == 2 ? -1.0 : 1.0

            @frequencies.each_with_index do |f, xi|
              raise ArgumentError, "Crossover frequency #{f} Hz must be below Nyquist" unless f < @sample_rate / 2
              g = Math.tan(Math::PI * f / @sample_rate)

              # Butterworth-squared lowpass and highpass chains; the first
              # section's filter gives both.
              sections = @order == 2 ? ks : ks + ks
              low = next_reg
              high = next_reg + 1
              next_reg += 2
              rows << svf_row(rest, low, high, SPLIT, g, sections[0], sign)
              sections.drop(1).each do |k|
                rows << svf_row(low, low, 0, LOW, g, k, 1.0)
                rows << svf_row(high, high, 0, HIGH, g, k, sign)
              end

              # The lower bands pass this crossover's allpass
              band_regs.each do |br|
                if @order == 2
                  rows << svf_row(br, br, 0, LOW_MINUS_HIGH, g, 2.0, 1.0)
                else
                  ks.each { |k| rows << svf_row(br, br, 0, ALLPASS, g, k, 1.0) }
                end
              end

              band_regs << low
              rest = high
            end
            band_regs << rest

            # Rows that update lower bands must run after the band was
            # produced, which the order above guarantees.
            program = Numo::DFloat.cast(rows.flatten)
            if keep_state && @state && @state.length == rows.length * 2
              @program = program
            else
              @program = program
              @state = Numo::DFloat.zeros(rows.length * 2)
            end
            @band_regs = band_regs
            @registers = next_reg
          end

          # A program row for an SVF at tan-warped frequency +g+ and damping
          # +k+ (Simper's a1, a2, a3).
          def svf_row(src, dst1, dst2, kind, g, k, sign)
            a1 = 1.0 / (1.0 + g * (g + k))
            a2 = g * a1
            a3 = g * a2
            [src, dst1, dst2, kind, a1, a2, a3, k, sign]
          end
        end
      end
    end
  end
end
