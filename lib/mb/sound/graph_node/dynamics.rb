module MB
  module Sound
    module GraphNode
      # A feed-forward dynamics processor: compressor, upward compressor,
      # expander, gate, ducker, or any compander, depending on its transfer
      # curve (Dynamics::Transfer).  One kernel, several faces: the DSL
      # methods in DynamicsMethods (#compress, #expand, #noise_gate, #duck,
      # #compand) build this node with different curves and times.  See
      # design/notes/dynamics.md.
      #
      # Each sample:
      # 1. The detector reads the sidechain (the input itself by default):
      #    :peak (|x|) or :rms (a one-pole mean square over +rms+), in dB
      #    (floor -200 dB).  Linked (default): one detector for every
      #    channel, following the loudest channel; unlinked: one per channel.
      # 2. The transfer curve gives the output level; the gain is output
      #    minus input level, clamped to +min_gain+..+max_gain+ (dB).
      # 3. The gain (dB) is smoothed by a one-pole: +down+ time while it
      #    falls, +up+ while it rises; while it is above 0 dB (an upward
      #    boost) it falls over +boost+ instead (default +down+), so a
      #    transient after a quiet stretch isn't let through boosted.
      #    +hold+ delays the rising direction (+hold_up: true+, compressors
      #    and ducks) or the falling one (gates), restarting whenever the
      #    gain moves the other way.
      # 4. The output is the input (delayed by +lookahead+ samples) times
      #    the gain plus +makeup+ (dB), mixed with the plain input by +mix+
      #    (parallel compression: gain = mix * gain + 1 - mix).
      #
      # Everything is per sample with state carried across buffers, so the
      # output is the same at any buffer size.  Times (+down+, +up+, +hold+,
      # +rms+) may be numbers (seconds), Lengths, Durations (following the
      # tempo), or nodes.  The kernel is MB::Sound::FastDynamics.compand;
      # .process_ruby is its exact Ruby mirror.
      #
      # It is a Channels bundle (one output per input channel); sample every
      # output once per buffer, as a Session does.
      class Dynamics < Channels
        # One output channel of a dynamics node.
        class Output
          include GraphNode
          include GraphNode::NodeOutput

          # The index of this output.
          attr_reader :index

          def initialize(owner:, index:, input:)
            @owner = owner
            @index = index
            @input = input
            @node_type_name = owner.class.name.rpartition('::').last
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
            s = { input: @input }
            @owner.sidechain_inputs&.each_with_index { |n, i| s[:"sidechain_#{i + 1}"] = n }
            s.merge(@owner.time_sources)
          end

          def to_s
            n = @owner.channel_count
            n == 1 ? @owner.to_s : "#{@owner} output #{@index + 1} of #{n}"
          end

          # Plan layer (see MB::Sound::Plan): a one-channel compander
          # (compress, expand, noise_gate, duck, compand) is a plan op
          # (Plan::Op::Dynamics); the owner says why others aren't (see
          # Dynamics#plan_unsupported_output).
          include Plan::Describable

          def plan_describe(p)
            @owner.plan_describe_output(p, self)
          end

          def plan_unsupported_reason
            @owner.plan_unsupported_output(self)
          end

          # Sidechains are always boundary inputs (another player's kick:
          # they may end, or come short, independently).
          def plan_boundary_inputs
            @owner.sidechain_inputs || []
          end

          def plan_snapshot
            @owner.plan_snapshot
          end

          def plan_restore(snapshot)
            @owner.plan_restore(snapshot)
          end

          # Short sidechain and time inputs are padded by the node (see
          # Dynamics#fit), so a block with one runs unfused (Region#gather).
          def plan_pads_inputs?
            true
          end

          # A sidechain or time input that ended reads as 0 from then on:
          # this block runs unfused, and the node stays unfused afterwards.
          def plan_input_ended(_source)
            region = @plan_region || @plan_member
            region&.installation&.exclude(self, 'a sidechain or time input ended')
            :replay
          end

          # True while the node holds delayed samples to flush after its
          # input ends (lookahead; see Plan::Region#prepare).
          def plan_tail?
            @owner.latency > 0
          end
        end

        # Shared buffer handling for multichannel dynamics nodes: samples
        # every input when an output starts a new frame (like
        # LoudnessMeter), and flushes +latency+ samples after the inputs end.
        module Framed
          # The sample rate.
          attr_reader :sample_rate

          # Called by the outputs: processes a new frame when output +index+
          # comes back for one, and returns its buffer (nil once ended).
          def sample_internal(count, index)
            if @sampled[index] || @frame.nil?
              if @sampled.any? && !@sampled.all?
                warn "#{self.class.name} output #{index} sampled again before the other outputs"
              end
              @sampled.fill(false)
              @frame = next_frame(count)
            end

            @sampled[index] = true
            @frame == :ended ? nil : @frame[index]
          end

          private

          # Reads the inputs (ended channels as silence while others play),
          # then the flush of +latency+ samples of silence, then :ended.
          def next_frame(count)
            return :ended if @ended

            data = @flushing ? nil : @inputs.map { |i| i.sample(count) }
            live = data&.compact&.reject(&:empty?)
            if live.nil? || live.empty?
              @flushing = true
              remaining = latency - @flushed
              if remaining <= 0
                @ended = true
                return :ended
              end
              n = [count, remaining].min
              @flushed += n
              data = Array.new(@inputs.length, nil)
            else
              n = live.map(&:length).min
              data = data.map { |d| d.nil? || d.empty? ? nil : (d.length > n ? d[0...n] : d) }
            end

            outs = Framed.next_buffers(self, @inputs.length, n)
            process(outs, data, n)
            outs
          end
        end

        include Framed

        # Output buffers alternate between two sets, so a Tee still sharing
        # one output's buffer from the last frame (its other branches not yet
        # read) never sees it change when another output starts the next
        # frame (as Plan::Region#swap_out! does for lane groups).
        def Framed.next_buffers(owner, count, n)
          sets = owner.instance_variable_get(:@buffer_sets) || owner.instance_variable_set(:@buffer_sets, [nil, nil])
          idx = owner.instance_variable_get(:@buffer_index) == 0 ? 1 : 0
          owner.instance_variable_set(:@buffer_index, idx)
          set = sets[idx]
          set = sets[idx] = Array.new(count) { Numo::SFloat.zeros(n) } if set.nil? || set[0].length != n
          set
        end

        # Detector modes.
        DETECTORS = [:peak, :rms].freeze

        # Detector level floor (dB) and the linear values below which it
        # applies, as in the kernel.
        FLOOR_DB = -200.0
        FLOOR_LIN = 1e-10
        FLOOR_SQ = 1e-20

        # Smoothed gains this close to their target land on it.
        SNAP = 1e-12

        # The transfer curve (Dynamics::Transfer).
        attr_reader :transfer

        # The sidechain nodes (sampler branches), or nil.
        attr_reader :sidechain_inputs

        # Settings.
        attr_reader :detector, :link, :lookahead, :makeup, :min_gain, :max_gain, :hold_up, :mix

        # The latest smoothed gain of each detector, in dB (without makeup).
        def gain_db
          Array.new(@detectors) { |d| @state[d * 3 + 1] }
        end

        # The current gain change of the first detector (dB, negative for
        # reduction), without makeup: a meter reading.
        def reduction
          @state[1]
        end

        # Creates a dynamics node for +inputs+ (a node or bundle, or an Array
        # of them; one output per channel).  See the class comment and
        # DynamicsMethods for the parameters.  +makeup+ is dB or :auto (half
        # the curve's gain at 0 dBFS back).
        def initialize(inputs, transfer:, down:, up:, hold: 0, hold_up: true, detector: :peak, rms: 0.01,
                       link: true, sidechain: nil, lookahead: 0, makeup: 0, min_gain: -Float::INFINITY,
                       max_gain: Float::INFINITY, boost: nil, mix: 1, description: nil)
          inputs = Array(inputs).flat_map { |n| GraphNode.dynamics_channels(n, 'Dynamics inputs') }
          raise ArgumentError, 'A dynamics node needs at least one channel' if inputs.empty?
          raise ArgumentError, "Detector must be one of #{DETECTORS.map(&:inspect).join(', ')} (got #{detector.inspect})" unless DETECTORS.include?(detector)
          raise ArgumentError, "Transfer must be a Dynamics::Transfer (got #{transfer.class})" unless transfer.is_a?(Transfer)

          @inputs = inputs.map(&:get_sampler)
          @sample_rate = @inputs[0].sample_rate.to_f
          @transfer = transfer
          @detector = detector
          @link = !!link
          @hold_up = !!hold_up
          @min_gain = DynamicsMethods.db_param(min_gain).to_f
          @max_gain = DynamicsMethods.db_param(max_gain).to_f
          raise ArgumentError, 'min_gain must not be above max_gain' if @min_gain > @max_gain

          # A Symbol names a bus or track to read (see BusTap)
          @sidechain_inputs = nil
          sidechain = BusTap.from(sidechain) if sidechain.is_a?(Symbol)
          if sidechain
            sc = Array(sidechain).flat_map { |n| GraphNode.dynamics_channels(n, 'Sidechains') }
            raise ArgumentError, 'Sidechain needs at least one channel' if sc.empty?
            if !@link && sc.length != 1 && sc.length != @inputs.length
              raise ArgumentError, "An unlinked sidechain needs 1 or #{@inputs.length} channels (got #{sc.length})"
            end
            @sidechain_inputs = sc.map(&:get_sampler)
          end

          @times = {
            rms: Length::Source.new(rms),
            down: Length::Source.new(down),
            up: Length::Source.new(up),
            boost: Length::Source.new(boost.nil? ? down : boost),
            hold: Length::Source.new(hold),
          }

          la = Length.samples(lookahead, sample_rate: @sample_rate)
          raise ArgumentError, "Lookahead must be a fixed length (got #{lookahead.inspect})" unless la.is_a?(Numeric)
          @lookahead_length = lookahead
          @lookahead = Length.snap(la).round
          raise ArgumentError, "Lookahead must not be negative (got #{lookahead.inspect})" if @lookahead < 0

          @makeup = makeup == :auto ? -0.5 * [@transfer.gain(0), @min_gain].max.clamp(@min_gain, @max_gain) : DynamicsMethods.db_param(makeup).to_f
          raise ArgumentError, "Makeup must be dB or :auto (got #{makeup.inspect})" unless @makeup.finite?

          raise ArgumentError, "Mix must be a number from 0 to 1 (got #{mix.inspect})" unless mix.is_a?(Numeric) && (0..1).cover?(mix)
          @mix = mix.to_f
          @detectors = @link ? 1 : @inputs.length
          @description = description || @transfer.to_s
          @sampled = Array.new(@inputs.length, false)
          @frame = nil
          @ended = false
          @flushing = false
          @flushed = 0
          @plan_curve = nil # (set later; see GraphNode::IvarPreset)
          @params = nil
          reset_state

          super(@inputs.each_with_index.map { |input, idx| Output.new(owner: self, index: idx, input: input) })
        end

        # The audio delay in samples (the lookahead).
        def latency
          @lookahead
        end

        # Sets the sample rate of every input (the lookahead stays the same
        # number of samples).
        def sample_rate=(rate)
          @inputs.each { |i| i.sample_rate = rate }
          @sidechain_inputs&.each { |i| i.sample_rate = rate }
          @sample_rate = rate.to_f
        end
        alias at_rate sample_rate=

        # Clears the detector, gain, and lookahead delay.
        def reset_state
          @state = Numo::DFloat.zeros(@detectors * 3 + 1)
          @delay = @lookahead > 0 ? Numo::DFloat.zeros(@inputs.length * @lookahead) : nil
          self
        end

        # Graph nodes giving times, for graph traversal.
        def time_sources
          @times.select { |_, s| s.node? }.transform_values(&:node)
        end

        def to_s
          "#{self.class.name.rpartition('::').last} #{@description}"
        end

        def to_s_graphviz
          "#{graph_node_name || self.class.name.rpartition('::').last}\n#{@description}"
        end

        # Plan layer: the reason output +output+ can't be a plan op, or nil
        # (see Output#plan_unsupported_reason).
        def plan_unsupported_output(output)
          return "a #{channel_count}-channel #{self.class.name.rpartition('::').last} (its channels run together in one kernel)" if channel_count != 1
          return 'flushing its delayed tail after its input ended' if @flushing || @ended

          nil
        end

        # Plan layer: one Plan::Op::Dynamics for +output+ (one channel): its
        # input, the detector signals (the input, or the sidechain channels
        # as optional boundary inputs), and the five times in samples.
        def plan_describe_output(p, output)
          x = p[output.sources[:input]]
          sides = @sidechain_inputs ? @sidechain_inputs.map { |s| p.boundary(s, optional: true) } : [x]
          times = @times.values.map { |src|
            if src.node?
              v = p.optional(src.node)
              src.unit == :seconds ? v * @sample_rate : v
            else
              src.constant_samples(@sample_rate)
            end
          }
          plan_params
          plan_curve
          p.dynamics(self, x, sides, times)
        end

        # The transfer curve's segments as the kernel reads them (for the
        # plan executor, which reads @plan_curve).
        def plan_curve
          @plan_curve ||= @transfer.table
        end

        # #params, kept (the kernel and the plan executor read @params).
        def plan_params
          @params ||= kernel_params
        end

        # The detector state, lookahead delay, and flush position (check
        # mode).
        def plan_snapshot
          [@state.to_a, @delay&.to_a, @flushing, @flushed, @ended]
        end

        def plan_restore(snapshot)
          state, delay, @flushing, @flushed, @ended = snapshot
          @state[true] = state
          @delay[true] = delay if delay
        end

        # Settings as the kernel reads them.
        def kernel_params
          Numo::DFloat[
            @detector == :rms ? 1 : 0, @min_gain, @max_gain, @makeup,
            @hold_up ? 1 : 0, @link ? 1 : 0, @lookahead, @mix
          ]
        end

        private

        def process(outs, data, n)
          sides = if @sidechain_inputs
            sc = @flushing ? [] : @sidechain_inputs.map { |s| fit(s.sample(n), n) }
            sc = [nil] if sc.empty?
            !@link && sc.length == 1 ? sc * @inputs.length : sc
          else
            data
          end

          times = @times.values.map { |s| fit(s.samples(n, @sample_rate) || 0, n) }
          @params ||= kernel_params
          MB::Sound::FastDynamics.compand(outs, data, sides, @transfer.table, @params, times, @state, @delay)
        end

        # +v+ as a kernel signal of +n+ samples: numbers and nil pass, long
        # buffers are cut, short ones padded with zeros.
        def fit(v, n)
          return v unless v.is_a?(Numo::NArray)
          return nil if v.empty?
          return v if v.length == n
          return v[0...n] if v.length > n
          out = v.class.zeros(n)
          out[0...v.length] = v
          out
        end

        public

        # The exact Ruby mirror of FastDynamics.compand (same arguments).
        def self.process_ruby(outs, ins, sides, curve, params, times, state, delay)
          n = outs[0].length
          nch = outs.length
          rms = params[0] != 0
          min_gain = params[1]
          max_gain = params[2]
          makeup = params[3]
          hold_up = params[4] != 0
          link = params[5] != 0
          la = params[6].to_i
          mix = params[7]
          ndet = link ? 1 : nch
          nside = sides.length

          table = curve.to_a
          segments = table.each_slice(5).to_a
          x_in = ins.map { |v| signal_values(v, n) }
          s_in = sides.map { |v| signal_values(v, n) }
          t_in = times.map { |v| signal_values(v, n) }

          pos = state[ndet * 3].to_i
          pos = 0 if la > 0 && (pos < 0 || pos >= la)

          last_t = [nil, nil, nil, nil, nil]
          coef = [0.0, 0.0, 0.0, 0.0, 0.0]
          last_gdb = nil
          last_glin = 1.0
          gain = Array.new(ndet, 1.0)
          at = ->(sig, i) { sig.is_a?(Array) ? sig[i] : sig }

          n.times do |i|
            4.times do |t|
              v = at.(t_in[t], i)
              if v != last_t[t]
                last_t[t] = v
                coef[t] = v > 0 ? Math.exp(-1.0 / v) : 0.0
              end
            end
            hold = at.(t_in[4], i)

            ndet.times do |d|
              base = d * 3
              m = 0.0
              (link ? (0...nside) : (d..d)).each do |c|
                v = at.(s_in[c], i)
                v = rms ? v * v : v.abs
                m = v if v > m
              end

              if rms
                state[base] = state[base] * coef[0] + (1.0 - coef[0]) * m
                level = state[base] > FLOOR_SQ ? 10.0 * Math.log10(state[base]) : FLOOR_DB
              else
                level = m > FLOOR_LIN ? 20.0 * Math.log10(m) : FLOOR_DB
              end

              g = Transfer.evaluate(segments, level) - level
              g = min_gain if g < min_gain
              g = max_gain if g > max_gain

              gs = state[base + 1]
              held = hold_up ? g > gs : g < gs
              if held && state[base + 2] > 0
                state[base + 2] -= 1.0
              else
                if g < gs && gs > 0
                  gs = g + (gs - g) * coef[3]
                elsif g != gs
                  gs = g + (gs - g) * (g < gs ? coef[1] : coef[2])
                end
                state[base + 2] = hold unless held
              end
              gs = g if (gs - g).abs < SNAP
              state[base + 1] = gs

              gdb = gs + makeup
              if gdb != last_gdb
                last_gdb = gdb
                last_glin = mix * 10.0 ** (gdb / 20.0) + (1.0 - mix)
              end
              gain[d] = last_glin
            end

            nch.times do |c|
              x = at.(x_in[c], i)
              if la > 0
                idx = c * la + pos
                y = delay[idx]
                delay[idx] = x
                x = y
              end
              outs[c][i] = x * gain[link ? 0 : c]
            end
            pos = pos + 1 == la ? 0 : pos + 1 if la > 0
          end

          state[ndet * 3] = pos.to_f
          outs
        end

        # A signal input as the kernels read it: a Float, or an Array of
        # float32 values (real parts of complex inputs).
        def self.signal_values(value, n)
          case value
          when nil then 0.0
          when Numeric then value.to_f
          when Numo::NArray
            raise ArgumentError, 'array length does not match sample buffer length' unless value.length == n
            v = value.is_a?(Numo::SComplex) || value.is_a?(Numo::DComplex) ? value.real : value
            Numo::SFloat.cast(v).to_a
          else
            raise ArgumentError, "Expected a number or NArray (got #{value.class})"
          end
        end
      end

      # The channels of +node+ (a node or bundle) for dynamics nodes,
      # raising for anything else.
      def self.dynamics_channels(node, what)
        unless node.is_a?(GraphNode) || node.is_a?(MultiOutput)
          raise ArgumentError, "#{what} must be graph nodes or bundles (got #{node.class})"
        end
        node.outputs
      end
    end
  end
end

require_relative 'dynamics/transfer'
require_relative 'dynamics/limiter'
require_relative 'dynamics/crossover'
