module MB
  module Sound
    module GraphNode
      class Dynamics
        # A transient shaper (effects-2): turns a sound's attacks and its
        # sustain up or down by level-independent amounts, from the
        # difference between envelope followers of different speeds.
        #
        # A peak envelope of the input (instant rise, a PEAK_RELEASE fall)
        # feeds three followers: a fast one (FAST attack, +release+), one
        # with a slow attack (+attack_time+, +release+), and one with a slow
        # release (FAST attack, +sustain_time+).  At an onset the fast one
        # jumps ahead of the slow-attack one: the attack share
        # a = 1 - slow / fast is near 1 at a sharp hit and 0 on a steady
        # sound.  As the sound decays the slow-release one stays above the
        # fast one: the sustain share s = 1 - fast / slow grows.  The gain in
        # dB is +attack+ * a + +sustain+ * s, so the amounts are the most
        # an attack (or a tail) moves, whatever its level.
        #
        # Linked across channels by default (one detector following the
        # loudest channel, so the stereo image holds).  No latency; the
        # output is the same at any buffer size.  Kernel
        # MB::Sound::FastDynamics.transient, exact Ruby mirror .process_ruby.
        # Built by DynamicsMethods#transients.
        class TransientShaper < Channels
          include Framed
          # (its followers' states: #carry_adopt)
          node_traits memory: :short, carry: :adopt

          # The peak envelope's fall (seconds): smooths the followers'
          # ripple on low notes (a 60 Hz sine read +-0.4 dB of attack gain
          # per 12 dB of attack amount without it, 0.04 with it).
          PEAK_RELEASE = 0.01

          # The fast followers' attack (seconds).
          FAST = 0.001

          # Settings.
          attr_reader :attack_time, :sustain_time, :release, :link

          # Creates a transient shaper for +inputs+ (a node or bundle, or an
          # Array of them; one output per channel).  +attack+ and +sustain+
          # are dB amounts (`6.db`; bare numbers are linear gains, nodes
          # too, as knobs of `6.db` are); the times are lengths (seconds by
          # default).
          def initialize(inputs, attack: 0.db, sustain: 0.db, attack_time: 0.01, sustain_time: 0.3, release: 0.05, link: true)
            inputs = Array(inputs).flat_map { |n| GraphNode.dynamics_channels(n, 'Transient shaper inputs') }
            raise ArgumentError, 'A transient shaper needs at least one channel' if inputs.empty?

            @inputs = inputs.map(&:get_sampler)
            @sample_rate = @inputs[0].sample_rate.to_f
            @attack = amount(attack, 'attack')
            @sustain = amount(sustain, 'sustain')
            @attack_time = attack_time
            @sustain_time = sustain_time
            @release = release
            [[attack_time, 'attack_time'], [sustain_time, 'sustain_time'], [release, 'release']].each do |t, name|
              v = Length.samples(t, sample_rate: @sample_rate)
              raise ArgumentError, "Transient shaper #{name} must be a fixed length of at least 0 (got #{t.inspect})" unless v.is_a?(Numeric) && v >= 0
            end
            @link = !!link
            @detectors = @link ? 1 : @inputs.length
            @held = [0.0, 0.0] # (the amount nodes' last values)
            @amounts = [nil, nil]
            @params = nil
            @sampled = Array.new(@inputs.length, false)
            @frame = nil
            @buffer_sets = nil # (Framed.next_buffers)
            @frame_data = Array.new(@inputs.length) # (Framed#next_frame)
            @buffer_index = nil
            @ended = false
            @flushing = false
            @flushed = 0
            reset_state

            super(@inputs.each_with_index.map { |input, idx| Output.new(owner: self, index: idx, input: input) })
          end

          # No latency.
          def latency
            0
          end

          # Plan layer: transient shapers stay unfused (see
          # Output#plan_unsupported_reason).
          def plan_unsupported_output(_output)
            'a transient shaper (its kernel is not a plan op yet)'
          end

          # The sidechain (none).
          def sidechain_inputs
            nil
          end

          # The amount nodes, for graph traversal.
          def time_sources
            s = {}
            s[:attack] = @attack unless @attack.is_a?(Float)
            s[:sustain] = @sustain unless @sustain.is_a?(Float)
            s
          end

          def sample_rate=(rate)
            @inputs.each { |i| i.sample_rate = rate }
            @sample_rate = rate.to_f
            @params = nil
          end
          alias at_rate sample_rate=

          # Session::Carry's adoption (NodeTraits' +carry+ :adopt): true if
          # shaper +old+ has as many detectors.
          def carry_fits?(old)
            old.class == self.class && old.instance_variable_get(:@state).shape == @state.shape
          end

          # Takes over shaper +old+'s follower states and ending.
          def carry_adopt(old)
            NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
          end

          ADOPT_IVARS = %i[@state @ended].freeze

          # Clears the followers.
          def reset_state
            @state = Numo::DFloat.zeros(@detectors * 4)
            self
          end

          # Settings as the kernel reads them (see FastDynamics.transient).
          def kernel_params
            Numo::DFloat[
              coefficient(PEAK_RELEASE), coefficient(FAST), coefficient(@attack_time), coefficient(@release),
              coefficient(@sustain_time), @link ? 1 : 0, Math.log(10.0) / 20.0,
            ]
          end

          def to_s
            "TransientShaper attack #{describe(@attack)}, sustain #{describe(@sustain)}"
          end

          def to_s_graphviz
            "#{graph_node_name || 'TransientShaper'}\nattack #{describe(@attack)}, sustain #{describe(@sustain)}"
          end

          private

          # A one-pole coefficient for +time+ (a length).
          def coefficient(time)
            t = Length.samples(time, sample_rate: @sample_rate).to_f
            t > 0 ? Math.exp(-1.0 / t) : 0.0
          end

          # An amount in dB: Decibels exactly, a bare number as a linear gain
          # (2 is +6 dB; Decibels.db_of's rule), or a node of linear gains
          # (a knob of `6.db`) read as dB every sample.
          def amount(value, name)
            return value.get_sampler.aclip(Dynamics::FLOOR_LIN, Float::INFINITY).log10 * 20 if value.respond_to?(:sample)
            Decibels.db_of(value, "transients #{name}").to_f
          end

          def describe(v)
            v.is_a?(Float) ? "#{MB::M.sigfigs(v, 3)} dB" : 'live'
          end

          # +n+ values of amount +i+: its Float, or its node's buffer (an
          # ended or short node holds its last value).
          def amount_values(i, n)
            c = i == 0 ? @attack : @sustain
            return c if c.is_a?(Float)

            v = c.sample(n)
            return @held[i] if v.nil? || v.empty?
            v = v[0...n] if v.length > n
            if v.length < n
              full = v.class.new(n).fill(v[-1])
              full[0...v.length] = v
              v = full
            end
            @held[i] = v[-1].to_f
            v
          end

          def process(outs, data, n)
            @params ||= kernel_params
            @amounts[0] = amount_values(0, n)
            @amounts[1] = amount_values(1, n)
            Kernels.transient(outs, data, @params, @amounts, @state)
          end

          public

          # The exact Ruby mirror of FastDynamics.transient (same arguments):
          # the same double operations in the same order, inputs read as
          # float32 values.
          def self.process_ruby(outs, ins, params, amounts, state)
            n = outs[0].length
            nch = outs.length
            raise ArgumentError, "Expected #{nch} inputs (got #{ins.length})" unless ins.length == nch
            raise ArgumentError, 'Expected two amounts (attack and sustain dB)' unless amounts.length == 2
            c_peak, c_fast, c_att, c_rel, c_sus = params[0], params[1], params[2], params[3], params[4]
            link = params[5] != 0
            db_scale = params[6]
            ndet = link ? 1 : nch
            raise ArgumentError, "State must have at least #{ndet * 4} elements" if state.length < ndet * 4

            x_in = ins.map { |v| Dynamics.signal_values(v, n) }
            am = amounts.map { |v| Dynamics.signal_values(v, n) }
            x = Array.new(nch, 0.0)
            gain = Array.new(ndet, 1.0)
            flush = 1e-30
            floor = 1e-10

            n.times do |i|
              nch.times { |c| x[c] = x_in[c].is_a?(Array) ? x_in[c][i] : x_in[c] }
              ad = am[0].is_a?(Array) ? am[0][i] : am[0]
              sd = am[1].is_a?(Array) ? am[1][i] : am[1]

              ndet.times do |d|
                l = x[d].abs
                if link
                  (1...nch).each { |c| v = x[c].abs; l = v if v > l }
                end

                b = d * 4
                p = state[b]
                p = l > p ? l : l + (p - l) * c_peak
                f = state[b + 1]
                f = p + (f - p) * (p > f ? c_fast : c_rel)
                sa = state[b + 2]
                sa = p + (sa - p) * (p > sa ? c_att : c_rel)
                sr = state[b + 3]
                sr = p + (sr - p) * (p > sr ? c_fast : c_sus)
                p = 0.0 if p < flush
                f = 0.0 if f < flush
                sa = 0.0 if sa < flush
                sr = 0.0 if sr < flush
                state[b] = p
                state[b + 1] = f
                state[b + 2] = sa
                state[b + 3] = sr

                a = f > sa && f > floor ? 1.0 - sa / f : 0.0
                s = sr > f && sr > floor ? 1.0 - f / sr : 0.0
                gain[d] = Math.exp((ad * a + sd * s) * db_scale)
              end

              nch.times { |c| outs[c][i] = x[c] * gain[link ? 0 : c] }
            end

            outs
          end
        end
      end

      Kernels.register :transient, c: FastDynamics.method(:transient), ruby: Dynamics::TransientShaper.method(:process_ruby)
    end
  end
end
