module MB
  module Sound
    module GraphNode
      class Dynamics
        # A lookahead brickwall limiter: the output never exceeds the
        # +ceiling+ (and with +true_peak+, its inter-sample peaks as BS.1770
        # Annex 2's 4x interpolator sees them stay there too, within about
        # 0.1 dB).  The gain falls in a straight line over the lookahead
        # before each peak (no distortion from an instant attack) and
        # recovers with a +release+ one-pole.  See design/notes/dynamics.md.
        #
        # Latency: +lookahead+ samples, plus 6 with +true_peak+ (the
        # interpolator's delay); #latency gives it.  Linked across channels
        # by default (a peak in either channel turns both down, keeping the
        # stereo image).
        #
        # Kernel MB::Sound::FastDynamics.limit, exact Ruby mirror
        # .process_ruby.  Built by DynamicsMethods#limit.
        class Limiter < Channels
          include Framed

          # Samples of delay added by the true-peak detector.
          TRUE_PEAK_DELAY = 6

          # BS.1770 Annex 2's 4x interpolator as a flat [phase, tap] DFloat
          # (Loudness::TruePeak::PHASES), for the kernel.
          def self.phases
            @phases ||= Numo::DFloat.cast(Loudness::TruePeak::PHASES.flatten).freeze
          end

          # Settings.
          attr_reader :ceiling, :lookahead, :release, :true_peak, :link

          # Creates a limiter for +inputs+ (a node or bundle, or an Array of
          # them).  +ceiling+ is a level (e.g. -1.db; see
          # DynamicsMethods for bare numbers); +lookahead+ and +release+ are lengths (seconds by
          # default).
          def initialize(inputs, ceiling: -1.db, lookahead: 0.0015, release: 0.1, true_peak: true, link: true)
            inputs = Array(inputs).flat_map { |n| GraphNode.dynamics_channels(n, 'Limiter inputs') }
            raise ArgumentError, 'A limiter needs at least one channel' if inputs.empty?

            @inputs = inputs.map(&:get_sampler)
            @sample_rate = @inputs[0].sample_rate.to_f
            @ceiling = DynamicsMethods.level(ceiling, 'ceiling')
            raise ArgumentError, "Ceiling must be above zero (got #{ceiling.inspect})" unless @ceiling > 0
            @lookahead_length = lookahead
            @lookahead = Length.snap(Length.samples(lookahead, sample_rate: @sample_rate)).round
            raise ArgumentError, 'Lookahead must not be negative' if @lookahead < 0
            @release = release
            @true_peak = !!true_peak
            @link = !!link
            @detectors = @link ? 1 : @inputs.length
            @sampled = Array.new(@inputs.length, false)
            @frame = nil
            @ended = false
            @flushing = false
            @flushed = 0
            reset_state

            super(@inputs.each_with_index.map { |input, idx| Output.new(owner: self, index: idx, input: input) })
          end

          # The audio delay in samples.
          def latency
            @lookahead + (@true_peak ? TRUE_PEAK_DELAY : 0)
          end

          # Plan layer: limiters stay unfused (see Output#plan_unsupported_reason).
          def plan_unsupported_output(_output)
            'a lookahead limiter (its sliding-window kernel is not a plan op yet)'
          end

          # The sidechain (none for limiters).
          def sidechain_inputs
            nil
          end

          # No time nodes.
          def time_sources
            {}
          end

          # The current gain of the first detector (dB).
          def reduction
            g = @state[0]
            g > 0 ? 20 * Math.log10(g) : -Float::INFINITY
          end

          def sample_rate=(rate)
            @inputs.each { |i| i.sample_rate = rate }
            @sample_rate = rate.to_f
            @params = nil
          end
          alias at_rate sample_rate=

          # Clears the gain, history, and delays.
          def reset_state
            nch = @inputs.length
            w = @lookahead + 1
            @state = Numo::DFloat.zeros(@detectors + nch + 1)
            @state[0...@detectors] = 1.0
            @rings = Numo::DFloat.zeros(2 * @detectors * w + nch * @lookahead + nch * 12)
            @rings[0...(2 * @detectors * w)] = 1.0
            self
          end

          # Settings as the kernel reads them.
          def kernel_params
            release = Length.samples(@release, sample_rate: @sample_rate)
            Numo::DFloat[@ceiling, release > 0 ? Math.exp(-1.0 / release) : 0.0, @lookahead, @true_peak ? 1 : 0, @link ? 1 : 0]
          end

          def to_s
            "Limiter #{MB::M.sigfigs(@ceiling.to_db, 3)} dB#{@true_peak ? 'TP' : ''}, #{@lookahead} samples lookahead"
          end

          def to_s_graphviz
            "#{graph_node_name || 'Limiter'}\n#{MB::M.sigfigs(@ceiling.to_db, 3)} dB#{@true_peak ? 'TP' : ''}"
          end

          private

          def process(outs, data, n)
            @params ||= kernel_params
            MB::Sound::FastDynamics.limit(outs, data, @params, @state, @rings, Limiter.phases)
          end

          public

          # The exact Ruby mirror of FastDynamics.limit (same arguments).
          def self.process_ruby(outs, ins, params, state, rings, phases)
            n = outs[0].length
            nch = outs.length
            ceiling = params[0]
            rc = params[1]
            la = params[2].to_i
            tp = params[3] != 0
            link = params[4] != 0
            w = la + 1
            ndet = link ? 1 : nch
            h = phases.to_a.each_slice(12).to_a

            greq_base = 0
            sm_base = ndet * w
            dl_base = sm_base + ndet * w
            hist_base = dl_base + nch * la
            counter = state[ndet + nch]
            x_in = ins.map { |v| Dynamics.signal_values(v, n) }
            lv = Array.new(nch, 0.0)
            a = Array.new(nch, 0.0)
            gain = Array.new(ndet, 1.0)

            n.times do |i|
              wpos = (counter % w).to_i
              dpos = la > 0 ? (counter % la).to_i : 0

              nch.times do |c|
                x = x_in[c].is_a?(Array) ? x_in[c][i] : x_in[c]
                if tp
                  hb = hist_base + c * 12
                  11.times { |k| rings[hb + k] = rings[hb + k + 1] }
                  rings[hb + 11] = x
                  peak = 0.0
                  4.times do |p|
                    y = 0.0
                    12.times { |k| y += rings[hb + 11 - k] * h[p][k] }
                    y = y.abs
                    peak = y if y > peak
                  end
                  a[c] = rings[hb + 11 - TRUE_PEAK_DELAY]
                  e = a[c].abs
                  e = peak if peak > e
                  e = state[ndet + c] if state[ndet + c] > e
                  state[ndet + c] = peak
                  lv[c] = e
                else
                  a[c] = x
                  lv[c] = x.abs
                end
              end

              ndet.times do |d|
                e = lv[d]
                (1...nch).each { |c| e = lv[c] if lv[c] > e } if link
                g = e > ceiling ? ceiling / e : 1.0

                gb = greq_base + d * w
                rings[gb + wpos] = g
                hmin = rings[gb]
                (1...w).each { |k| hmin = rings[gb + k] if rings[gb + k] < hmin }

                s = state[d]
                s = hmin < s ? hmin : hmin + (s - hmin) * rc
                s = hmin if (s - hmin).abs < SNAP
                state[d] = s

                sb = sm_base + d * w
                rings[sb + wpos] = s
                sum = 0.0
                w.times { |k| sum += rings[sb + k] }
                gain[d] = sum / w.to_f
              end

              nch.times do |c|
                x = a[c]
                if la > 0
                  idx = dl_base + c * la + dpos
                  y = rings[idx]
                  rings[idx] = x
                  x = y
                end
                y = x * gain[link ? 0 : c]
                if y > ceiling
                  y = ceiling
                elsif y < -ceiling
                  y = -ceiling
                end
                outs[c][i] = y
              end

              counter += 1.0
            end

            state[ndet + nch] = counter
            outs
          end
        end
      end
    end
  end
end
