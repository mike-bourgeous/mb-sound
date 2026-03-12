require 'matrix'

module MB
  module Sound
    module GraphNode
      # A reverb effect built from diffusion stages and a feedback delay network
      # (FDN).  Processes mono input through multiple parallel delay channels
      # to create a dense, natural-sounding reverb tail.
      #
      # Signal flow: input -> Diffusion (M steps) -> FDN -> wet/dry mix -> output
      #
      # The diffusion stages use Hadamard matrices to spread energy across
      # channels, while the FDN uses a Householder reflection matrix for
      # feedback mixing.
      #
      # Examples (in bin/sound.rb):
      #     play 440.hz.sine.for(0.5).reverb
      #     play 440.hz.sine.for(0.5).reverb(room_size: 0.8, decay: 3.0, damping: 0.7)
      #
      # See also bin/reverb.rb for a command-line demo script.
      class Reverb
        include GraphNode
        include BufferHelper
        include SampleRateHelper

        # Range for randomized diffusion delay times in seconds (short, 1-15ms).
        DIFFUSION_DELAY_RANGE = (0.001..0.015)

        # Range for randomized FDN delay times in seconds (longer, 15-120ms).
        FDN_DELAY_RANGE = (0.015..0.120)

        # The input source node.
        attr_reader :sources

        # Creates a new Reverb node that processes audio from the given +input+.
        #
        # Parameters:
        # - +input+ - Upstream graph node providing mono audio
        # - +room_size+ - 0.0..1.0, scales delay times (default: 0.5)
        # - +decay+ - Target RT60 decay time in seconds (default: 2.0)
        # - +damping+ - 0.0..1.0, higher = more HF absorption (default: 0.5)
        # - +diffusion_steps+ - Number of serial diffusion stages (default: 4)
        # - +channels+ - Number of parallel delay channels, must be power of 2 (default: 8)
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
          wet: 0.3,
          dry: 0.7,
          seed: 0,
          sample_rate: 48000
        )
          raise 'Input must respond to :sample' unless input.respond_to?(:sample)
          raise 'Channels must be a power of 2' unless channels > 0 && (channels & (channels - 1)) == 0
          raise 'Room size must be between 0.0 and 1.0' unless room_size >= 0.0 && room_size <= 1.0
          raise 'Damping must be between 0.0 and 1.0' unless damping >= 0.0 && damping <= 1.0
          raise 'Decay must be positive' unless decay > 0

          @input = input
          @sample_rate = sample_rate.to_f
          @channels = channels
          @wet = wet.to_f
          @dry = dry.to_f

          @graph_node_name = 'Reverb'

          @sources = { input: @input }.freeze

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
            delays = self.class.random_delays(
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

          setup_buffer(length: 1)
        end

        # Processes +count+ samples from the upstream source through diffusion
        # and FDN, then applies wet/dry mix.
        def sample(count)
          data = @input.sample(count)
          return nil if data.nil?

          expand_buffer(data, grow: true)

          # Replicate mono input to N channels for diffusion input
          channels = @channels.times.map { data.dup }

          # Process through diffusion stages in series
          @diffusion_steps.each do |step|
            channels = step.process(channels)
          end

          # Process through FDN -> mono output
          wet_signal = @fdn.process(channels)

          # Wet/dry mix
          @dry * data + @wet * wet_signal
        end

        # Resets all internal state (delay lines, filters, feedback buffers).
        def reset
          @diffusion_steps.each(&:reset)
          @fdn.reset
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
        # linear spacing within +range+, scaled by +room_scale+.  The range
        # is divided into +n+ equal sub-intervals and one random value is
        # picked from each, guaranteeing spread across the full range.
        def self.random_delays(n, range, room_scale, rng)
          step = (range.end - range.begin) / n.to_f
          n.times.map { |i|
            lo = range.begin + i * step
            hi = lo + step
            rng.rand(lo..hi) * room_scale
          }
        end

        # Generates +n+ random delay times (in seconds) using stratified
        # log-spacing within +range+, scaled by +room_scale+.  The log range
        # is divided into +n+ equal sub-intervals and one random value is
        # picked from each, guaranteeing even multiplicative spread and
        # avoiding the clustering that causes comb-filter artifacts.
        #
        # Delay sets where any pair of delays has a ratio within +tolerance+
        # of a small integer (2, 3, or 4) are rejected and re-rolled, up to
        # +max_attempts+ times.  This prevents the comb-filter reinforcement
        # that causes audible flutter echo in the reverb tail.
        def self.log_random_delays(n, range, room_scale, rng, tolerance: 0.05, max_attempts: 50)
          log_min = Math.log(range.begin)
          log_max = Math.log(range.end)
          step = (log_max - log_min) / n.to_f

          generate = -> {
            n.times.map { |i|
              lo = log_min + i * step
              hi = lo + step
              Math.exp(rng.rand(lo..hi)) * room_scale
            }
          }

          max_attempts.times do
            delays = generate.call
            return delays if delays_non_harmonic?(delays, tolerance)
          end

          generate.call
        end

        # Returns true if no pair of +delays+ has a ratio within +tolerance+
        # of a small integer (2, 3, or 4).
        def self.delays_non_harmonic?(delays, tolerance)
          delays.combination(2).all? { |a, b|
            ratio = a > b ? a / b : b / a
            (2..4).none? { |int| (ratio - int).abs < tolerance }
          }
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

            @output_scale = 1.0 / Math.sqrt(@n)
          end

          # Processes N input channels through the FDN and returns a mono
          # NArray (sum of delayed outputs scaled by 1/sqrt(N)).
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

            # Sum to mono
            mono = Numo::SFloat.zeros(count)
            delayed.each { |ch| mono = mono + ch }
            mono * @output_scale
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
