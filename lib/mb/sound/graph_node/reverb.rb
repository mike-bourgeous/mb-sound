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

        # Base delay times in seconds for diffusion steps (short, 1-12ms range).
        # These are scaled by room_size and offset per step.
        DIFFUSION_BASE_DELAYS = [
          0.0037, 0.0051, 0.0071, 0.0097,
        ].freeze

        # Base delay times in seconds for FDN delay lines (longer, 20-90ms range).
        # Chosen to be mutually prime-ish to avoid modal resonance.
        FDN_BASE_DELAYS = [
          0.0293, 0.0371, 0.0411, 0.0461,
          0.0533, 0.0587, 0.0699, 0.0893,
        ].freeze

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
        # - +channels+ - Number of parallel delay channels, must be power of 2 (default: 4)
        # - +wet+ - Wet signal gain (default: 0.3)
        # - +dry+ - Dry signal gain (default: 0.7)
        # - +sample_rate+ - Sample rate in Hz (default: 48000)
        def initialize(
          input,
          room_size: 0.5,
          decay: 2.0,
          damping: 0.5,
          diffusion_steps: 4,
          channels: 4,
          wet: 0.3,
          dry: 0.7,
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

          # Build the Hadamard matrix for diffusion (shared by all diffusion steps)
          hadamard = self.class.hadamard_matrix(channels)

          # Build diffusion steps
          @diffusion_steps = diffusion_steps.times.map { |step|
            delays = channels.times.map { |ch|
              base = DIFFUSION_BASE_DELAYS[ch % DIFFUSION_BASE_DELAYS.length]
              offset = (step * 0.0013) + (ch * 0.0007)
              (base + offset) * (0.3 + room_size * 0.7)
            }
            DiffusionStep.new(delays, hadamard, sample_rate: @sample_rate)
          }

          # Build FDN
          fdn_delays = channels.times.map { |ch|
            base = FDN_BASE_DELAYS[ch % FDN_BASE_DELAYS.length]
            base * (0.3 + room_size * 0.7)
          }
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
            @min_delay_samples = @delay_samples.min

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
          # If the buffer size exceeds the shortest delay, processing is
          # done in sub-blocks to avoid feedback timing issues.
          def process(channels)
            count = channels[0].length

            if count > @min_delay_samples && @min_delay_samples > 0
              # Sub-block processing
              result = Numo::SFloat.zeros(count)
              offset = 0
              while offset < count
                block_size = [count - offset, @min_delay_samples].min
                sub_channels = channels.map { |ch| ch[offset...(offset + block_size)] }
                result[offset...(offset + block_size)] = process_block(sub_channels)
                offset += block_size
              end
              result
            else
              process_block(channels)
            end
          end

          # Resets all delay lines, filters, and feedback buffers.
          def reset
            @delays.each { |d| d.reset }
            @lowpasses.each { |lp| lp.reset }
            @feedback = @n.times.map { Numo::SFloat.zeros(1) }
          end

          private

          # Processes a single block of N channels through the FDN.
          def process_block(channels)
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
        end
      end
    end
  end
end
