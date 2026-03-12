require 'matrix'
require 'forwardable'

module MB
  module Sound
    module GraphNode
      # A reverb effect built from diffusion stages and a feedback delay network
      # (FDN).  Processes one or more input channels through shared diffusion
      # and FDN infrastructure, producing one or more output channels.
      #
      # Signal flow:
      #   M inputs → [distribute to N channels] → Diffusion → FDN → [extract P outputs] → wet/dry mix → P outputs
      #
      # - N = internal delay channels (power of 2, the +channels+ parameter)
      # - M = number of input nodes
      # - P = number of output channels (+output_channels+ parameter, defaults to M)
      #
      # Input distribution uses wrapped round-robin: inputs are assigned to
      # internal channels sequentially, wrapping when N is exceeded.  Output
      # extraction uses the same pattern in reverse.
      #
      # When P > 1, includes MultiOutput and provides a ReverbOutput inner
      # class for each output.  When P == 1, behaves as a simple mono node.
      #
      # Examples (in bin/sound.rb):
      #     play 440.hz.sine.for(0.5).reverb
      #     play 440.hz.sine.for(0.5).reverb(room_size: 0.8, decay: 3.0, damping: 0.7)
      #
      #     # Stereo input from a file
      #     l, r = file_input('sounds/synth0.flac').split
      #     play [l, r].reverb
      #
      # See also bin/reverb.rb for a command-line demo script.
      class Reverb
        include GraphNode
        include MultiOutput
        include BufferHelper
        include SampleRateHelper

        # Range for randomized diffusion delay times in seconds (short, 1-15ms).
        DIFFUSION_DELAY_RANGE = (0.001..0.015)

        # Range for randomized FDN delay times in seconds (longer, 15-120ms).
        FDN_DELAY_RANGE = (0.015..0.120)

        # The input source node.
        attr_reader :sources

        # The output nodes (Array of ReverbOutput or [self] for mono).
        attr_reader :outputs

        # Represents a single output channel of a multichannel reverb.
        # Delegates to the parent Reverb via sample_internal.
        class ReverbOutput
          extend Forwardable
          include GraphNode
          include GraphNode::SampleRateHelper
          include GraphNode::NodeOutput

          def_delegators :@reverb, :sample_rate

          # Creates an output node for the given +reverb+ at the given +index+.
          def initialize(reverb:, index:)
            @owner = reverb
            @reverb = reverb
            @index = index
            @graph_node_name = "Reverb output #{index}"
          end

          def sample(count)
            @reverb.sample_internal(count, @index)
          end

          def sample_rate=(rate)
            @reverb.sample_rate = rate
            self
          end

          def sources
            { reverb: @reverb }
          end

          def to_s
            "Reverb output #{@index} of #{@reverb.output_channel_count}"
          end
        end

        # The number of output channels.
        attr_reader :output_channel_count

        # Creates a new Reverb node that processes audio from the given +input+.
        #
        # Parameters:
        # - +input+ - Upstream graph node or Array of graph nodes providing audio
        # - +room_size+ - 0.0..1.0, scales delay times (default: 0.5)
        # - +decay+ - Target RT60 decay time in seconds (default: 2.0)
        # - +damping+ - 0.0..1.0, higher = more HF absorption (default: 0.5)
        # - +diffusion_steps+ - Number of serial diffusion stages (default: 4)
        # - +channels+ - Number of parallel delay channels, must be power of 2 (default: 8)
        # - +output_channels+ - Number of output channels (default: nil, match input count)
        # - +wet+ - Wet signal gain (default: 0.3)
        # - +dry+ - Dry signal gain (default: 0.7)
        # - +seed+ - Random seed for delay time generation (default: 0)
        # - +sample_rate+ - Sample rate in Hz (default: 48000)
        def initialize(
          input,
          room_size: 0.5,
          decay: 2.0,
          damping: 0.5,
          diffusion_steps: 4,
          channels: 8,
          output_channels: nil,
          wet: 0.3,
          dry: 0.7,
          seed: 0,
          sample_rate: 48000
        )
          @inputs = Array(input)
          raise 'At least one input is required' if @inputs.empty?
          @inputs.each { |inp|
            raise 'Input must respond to :sample' unless inp.respond_to?(:sample)
          }

          input_count = @inputs.length
          @output_channel_count = output_channels || input_count

          # Auto-bump channels to accommodate inputs and outputs, then next power of 2
          channels = [channels, input_count, @output_channel_count].max
          channels = next_power_of_2(channels)

          raise 'Room size must be between 0.0 and 1.0' unless room_size >= 0.0 && room_size <= 1.0
          raise 'Damping must be between 0.0 and 1.0' unless damping >= 0.0 && damping <= 1.0
          raise 'Decay must be positive' unless decay > 0

          @sample_rate = sample_rate.to_f
          @channels = channels
          @wet = wet.to_f
          @dry = dry.to_f

          @graph_node_name = 'Reverb'

          if @inputs.length == 1
            @sources = { input: @inputs[0] }.freeze
          else
            @sources = @inputs.each_with_index.map { |inp, idx|
              [:"input_#{idx}", inp]
            }.to_h.freeze
          end

          rng = Random.new(seed)
          room_scale = 0.3 + room_size * 0.7

          # Build the Hadamard matrix for diffusion (shared by all diffusion steps)
          hadamard = self.class.hadamard_matrix(channels)

          # Build diffusion steps with progressively longer delay ranges.
          # Step 1 uses 0..max/N, step 2 uses 0..2*max/N, etc., so earlier
          # steps create short, tight reflections and later steps spread
          # energy across a wider time range.
          diff_max = DIFFUSION_DELAY_RANGE.end
          diff_min = DIFFUSION_DELAY_RANGE.begin
          @diffusion_steps = diffusion_steps.times.map { |step|
            step_max = diff_min + (diff_max - diff_min) * (step + 1).to_f / diffusion_steps
            step_range = (diff_min..step_max)
            delays = self.class.log_random_delays(
              channels, step_range, room_scale, rng
            ).sort
            DiffusionStep.new(delays, hadamard, sample_rate: @sample_rate)
          }

          # Build FDN with log-spaced random delay times for even
          # multiplicative spread across the range
          fdn_delays = self.class.log_random_delays(
            channels, FDN_DELAY_RANGE, room_scale, rng
          )
          @fdn = FDN.new(
            fdn_delays,
            decay: decay,
            damping: damping,
            sample_rate: @sample_rate
          )

          # Build output nodes
          if @output_channel_count > 1
            @outputs = Array.new(@output_channel_count) { |idx|
              ReverbOutput.new(reverb: self, index: idx)
            }.freeze
          else
            @outputs = [self].freeze
          end

          # Tracking set for multi-output sampling (like MatrixMixer)
          @sampled_set = Set.new
          @output_data = nil

          setup_buffer(length: 1)
        end

        # Processes +count+ samples from the upstream source through diffusion
        # and FDN, then applies wet/dry mix.  For multichannel reverb, returns
        # output channel 0.
        def sample(count)
          sample_internal(count, 0)
        end

        # Called by ReverbOutput#sample (or #sample for output 0) to process
        # all inputs and return the data for a specific output index.
        def sample_internal(count, index)
          if @sampled_set.include?(index) || @output_data.nil?
            if @sampled_set.length != 0 && @sampled_set.length != @output_channel_count
              warn "Reverb output #{index} sampled again before other outputs"
            end

            @sampled_set.clear

            # Sample all inputs
            inputs_data = @inputs.map { |inp| inp.sample(count) }
            return nil if inputs_data.any?(&:nil?)

            expand_buffer(inputs_data[0], grow: true)

            m = @inputs.length
            n = @channels
            p = @output_channel_count

            # Distribute M inputs to N channels (wrapped round-robin)
            channels = Array.new(n) { Numo::SFloat.zeros(count) }
            total_in = m * (n.to_f / m).ceil
            total_in.times do |k|
              channels[k % n] = channels[k % n] + inputs_data[k % m]
            end

            # Process through diffusion stages in series
            @diffusion_steps.each do |step|
              channels = step.process(channels)
            end

            # Process through FDN -> array of N delayed channels
            delayed = @fdn.process(channels)

            # Extract P outputs from N channels (wrapped round-robin)
            wet_outputs = Array.new(p) { Numo::SFloat.zeros(count) }
            total_out = p * (n.to_f / p).ceil
            total_out.times do |k|
              wet_outputs[k % p] = wet_outputs[k % p] + delayed[k % n]
            end
            scale = 1.0 / Math.sqrt((n.to_f / p).ceil)
            wet_outputs.map! { |o| o * scale }

            # Wet/dry mix per output
            @output_data = Array.new(p) { |k|
              @dry * inputs_data[k % m] + @wet * wet_outputs[k]
            }
          end

          return nil if @output_data.nil?

          @sampled_set << index

          @output_data[index]
        end

        # Resets all internal state (delay lines, filters, feedback buffers).
        def reset
          @diffusion_steps.each(&:reset)
          @fdn.reset
          @sampled_set.clear
          @output_data = nil
        end

        # Constructs a normalized Hadamard matrix wrapped in a ProcessingMatrix.
        def self.hadamard_matrix(n)
          raw = MB::M.hadamard(n)
          scale = 1.0 / Math.sqrt(n)
          normalized = raw.map { |row| row.map { |v| v * scale } }
          MB::Sound::ProcessingMatrix.new(Matrix[*normalized])
        end

        # Constructs a Householder reflection matrix wrapped in a ProcessingMatrix.
        # The matrix is I - (2/N) * ones(N, N), which is orthogonal and symmetric.
        def self.householder_matrix(n)
          m = Matrix.identity(n) - Matrix.build(n, n) { 2.0 / n }
          MB::Sound::ProcessingMatrix.new(m)
        end

        # Generates +n+ random delay times (in seconds) using stratified
        # log-spacing within +range+, scaled by +room_scale+.  The log range
        # is divided into +n+ equal sub-intervals and one random value is
        # picked from each, guaranteeing even multiplicative spread and
        # avoiding the clustering that causes comb-filter artifacts.
        #
        # Delay sets where any pair has a ratio within +tolerance+ of a
        # small integer (2, 3, or 4) are rejected and re-rolled up to
        # +max_attempts+ times.  This prevents the comb-filter
        # reinforcement that causes audible flutter echo.
        def self.log_random_delays(n, range, room_scale, rng, tolerance: 0.08, max_attempts: 50)
          log_min = Math.log(range.begin)
          log_max = Math.log(range.end)
          step = (log_max - log_min) / n.to_f

          delays = nil
          max_attempts.times do
            delays = n.times.map { |i|
              lo = log_min + i * step
              hi = lo + step
              Math.exp(rng.rand(lo..hi)) * room_scale
            }

            break if delays_non_harmonic?(delays, tolerance)
          end

          delays
        end

        # Returns true if no pair of +delays+ has a ratio within +tolerance+
        # of a small integer (2, 3, or 4).
        def self.delays_non_harmonic?(delays, tolerance)
          delays.combination(2).all? { |a, b|
            ratio = a > b ? a / b : b / a
            (2..4).none? { |int| (ratio - int).abs < tolerance }
          }
        end

        private

        # Returns the next power of 2 >= n.
        def next_power_of_2(n)
          return 1 if n <= 1
          v = n - 1
          v |= v >> 1
          v |= v >> 2
          v |= v >> 4
          v |= v >> 8
          v |= v >> 16
          v + 1
        end

        # One stage of the diffusion chain.  Takes N channels in, delays each
        # independently, mixes through a Hadamard matrix, and outputs N channels.
        class DiffusionStep
          # Creates a diffusion step with the given +delay_times+ (in seconds,
          # one per channel) and a +mixing_matrix+ (ProcessingMatrix).
          def initialize(delay_times, mixing_matrix, sample_rate: 48000)
            @delays = delay_times.map { |dt|
              MB::Sound::Filter::Delay.new(
                delay: dt,
                sample_rate: sample_rate,
                buffer_size: (dt * sample_rate * 1.5).ceil + 1,
                smoothing: false,
                feedback: false
              )
            }
            @matrix = mixing_matrix
          end

          # Processes an Array of N NArrays (one per channel) through delays
          # and the Hadamard mixing matrix.  Returns an Array of N NArrays.
          def process(channels)
            delayed = channels.each_with_index.map { |ch, i|
              @delays[i].process(ch).not_inplace!
            }
            @matrix.process(delayed)
          end

          # Resets all delay lines in this step.
          def reset
            @delays.each { |d| d.reset }
          end
        end

        # Feedback Delay Network with N parallel delay lines, per-channel
        # lowpass damping, and Householder reflection feedback mixing.
        class FDN
          # Creates an FDN with the given +delay_times+ (in seconds, one per
          # channel).
          #
          # Parameters:
          # - +delay_times+ - Array of delay times in seconds (one per channel)
          # - +decay+ - Target RT60 time in seconds
          # - +damping+ - 0.0..1.0, controls lowpass cutoff in feedback path
          # - +sample_rate+ - Sample rate in Hz
          def initialize(delay_times, decay: 2.0, damping: 0.5, sample_rate: 48000)
            @sample_rate = sample_rate.to_f
            @n = delay_times.length

            @delays = delay_times.map { |dt|
              MB::Sound::Filter::Delay.new(
                delay: dt,
                sample_rate: sample_rate,
                buffer_size: (dt * sample_rate * 1.5).ceil + 1,
                smoothing: false,
                feedback: false
              )
            }

            @delay_samples = delay_times.map { |dt| (dt * @sample_rate).round }

            # Per-channel feedback gain for RT60-consistent decay
            # g_i = 10^(-3 * d_i / (decay * sample_rate))
            @gains = @delay_samples.map { |d|
              10.0 ** (-3.0 * d / (decay * @sample_rate))
            }

            # Damping lowpass filters
            cutoff = @sample_rate * 0.49 * (1.0 - damping * 0.9)
            @lowpasses = @n.times.map {
              MB::Sound::Filter::Cookbook.new(
                :lowpass, @sample_rate, cutoff, quality: 0.5
              )
            }

            # Householder feedback matrix
            @matrix = Reverb.householder_matrix(@n)

            # Feedback buffers (N channels, initially zeros)
            @feedback = @n.times.map { Numo::SFloat.zeros(1) }
          end

          # Processes N input channels through the FDN and returns an Array
          # of N delayed NArrays.
          #
          # Feedback is applied once per buffer: the previous block's mixed
          # output is added to the current input before entering the delay
          # lines.  This means the effective minimum feedback period equals
          # the buffer size, so callers should keep buffers reasonably short
          # (e.g. 480-960 samples) for best results.
          def process(channels)
            count = channels[0].length

            # Resize feedback buffers if needed
            @feedback.each_with_index do |fb, i|
              if fb.length != count
                @feedback[i] = Numo::SFloat.zeros(count)
              end
            end

            # Add input + feedback -> delay -> lowpass -> gain
            delayed = @n.times.map { |i|
              mixed = channels[i] + @feedback[i]
              d = @delays[i].process(mixed).not_inplace!
              d = @lowpasses[i].process(d)
              d * @gains[i]
            }

            # Mix through Householder matrix -> feedback for next block
            @feedback = @matrix.process(delayed)

            delayed
          end

          # Resets all delay lines, filters, and feedback buffers.
          def reset
            @delays.each { |d| d.reset }
            @lowpasses.each { |lp| lp.reset }
            @feedback = @n.times.map { Numo::SFloat.zeros(1) }
          end
        end
      end
    end
  end
end
