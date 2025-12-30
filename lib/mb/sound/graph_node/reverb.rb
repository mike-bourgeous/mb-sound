module MB
  module Sound
    module GraphNode
      # An artificial reverberation algorithm based on a presentation by
      # Geraint Luff at ADC21.  The basic algorithm is a number of
      # delay-and-mix diffusion steps followed by a feedback delay network.
      #
      # See MB::Sound::GraphNode#reverb for a starting point for parameters, as
      # it's easy to make something that sounds bad.
      #
      # Example (bin/sound.rb):
      #     play file_input('sounds/drums.flac').reverb
      class Reverb
        include GraphNode
        include GraphNode::SampleRateHelper

        # Initializes a reverb node with the given parameters.  See
        # MB::Sound::GraphNode#reverb for some example defaults.
        #
        # +:upstream+ - The source node to which to apply reverb.
        # +:diffusion_channels+ - The number of parallel paths for diffusion
        #                         and feedback.  Higher means more diffusion
        #                         but more CPU usage.  Must be a power of two,
        #                         with 4 to 16 being good values.
        # +:stages+ - The number of diffusion stages.  4 is a good default.
        # +:diffusion_range+ - The diffusion delay range in seconds.  May be a
        #                      Range or a Numeric upper bound.  0.01 (10ms) is
        #                      a good starting point for experimentation.
        #                      Larger values blur the sound more but cause more
        #                      predelay.
        # +:feedback_range+ - The feedback delay range in seconds.  This should
        #                     be high enough that feedback doesn't amplify
        #                     audible frequencies, so at least 0.1s.
        # +:feedback_gain+ - The linear volume of feedback in the feedback
        #                    loop.  Must be less than 1.0 to avoid overload.
        # +:wet+ - The reverberated signal output level.  Usually 1.0.
        # +:dry+ - The original signal output level.  Usually 1.0.
        def initialize(upstream:, diffusion_channels:, stages:, diffusion_range:, feedback_range:, feedback_gain:, sample_rate:, wet:, dry:)
          @sample_rate = sample_rate.to_f
          @upstream = upstream
          check_rate(@upstream, 'upstream')

          @upstream_sampler = upstream.get_sampler.named('Reverb upstream')
          @channels = Integer(diffusion_channels)
          @stages = Integer(stages)

          diffusion_range = 0..diffusion_range.to_f if diffusion_range.is_a?(Numeric)
          @diffusion_range = diffusion_range

          feedback_range = 0..feedback_range.to_f if feedback_range.is_a?(Numeric)
          @feedback_range = feedback_range

          @wet = wet.to_f
          @dry = dry.to_f
          @feedback_gain = feedback_gain.to_f

          # FIXME: adjust gain or use compression or something based on feedback gain
          # FIXME: gain based on number of stages is wrong
          # FIXME: stupid amounts of predelay
          # TODO: stereo or multichannel output based on channel subset mixing
          # TODO: stereo or multichannel input
          # TODO: infinite reverb where feedback loop is normalized and
          # feedback gain is proportional to input volume from diffusion stage

          # Create diffusers with delays evenly spaced across the range
          #
          # TODO: consider uneven spacing e.g. placing more near the start
          delay_span = @diffusion_range.end - @diffusion_range.begin
          last_stage = nil
          @diffusers = Array.new(@stages) do |idx|
            delay_end = @diffusion_range.begin + delay_span * (idx + 1)
            delay_range = 0..delay_end
            last_stage = make_diffuser(
              channels: @channels,
              delay_range: delay_range,
              input: last_stage || @upstream
            )
          end

          # Normal for reflection plane for Householder matrix, making sure
          # each dimension is nonzero
          @normal = Vector[*Array.new(@channels) { |c| rand((c * 0.5 / @channels)..1) * (rand > 0.5 ? 1 : -1) }].normalize

          @feedback = Array.new(@channels) { Numo::SFloat.zeros(48000) }
          @feedback_network = make_fdn(@diffusers.last)
        end

        # For internal use.  Creates and returns a single diffuser stage as an
        # Array of GraphNodes that will delay, shuffle, and remix the input(s).
        def make_diffuser(channels:, delay_range:, input:)
          delay_span = (delay_range.end - delay_range.begin).to_f / channels

          hadamard = MB::M.hadamard(channels) # .transpose.shuffle.transpose.shuffle

          nodes = Array.new(channels) do |idx|
            delay_begin = delay_range.begin + delay_span * idx
            delay_end = delay_begin + delay_span
            delay_time = rand(delay_begin..delay_end)

            if input.is_a?(Array)
              source = input[idx]
            else
              source = input.get_sampler.named("Reverb diffusion #{idx + 1}")
            end

            wet_gain = rand > 0.5 ? 1 : -1

            # Delay and inversion step (wet gain 1 or -1)
            source.delay(seconds: delay_time, wet: wet_gain, smoothing: false, max_delay: MB::M.max(delay_range.end, 1.0))
          end

          # Hadamard mixing step
          matrix = MB::Sound::GraphNode::MatrixMixer.new(matrix: hadamard, inputs: nodes, sample_rate: @sample_rate)
          matrix.outputs.shuffle
        end

        # For internal use.  Creates the feedback delay network, minus the
        # mixing stage (implemented in #sample).
        def make_fdn(inputs)
          inputs.map.with_index { |inp, idx|
            inp
              .proc { |v| v + @feedback[idx][0...v.length] }
              .delay(seconds: rand(@feedback_range), smoothing: false, max_delay: MB::M.max(@feedback_range.end, 1.0), wet: @feedback_gain)
          }
        end

        # Returns the input source, and if +:internal+ is true, the feedback
        # and diffusion network.
        def sources(internal: false)
          {
            input: @upstream_sampler,
            **(internal ? @feedback_network.map.with_index { |v, idx| [:"channel_#{idx + 1}", v] }.to_h : {})
          }
        end

        # Sets the sample rate of the upstream source and internal components.
        def sample_rate=(rate)
          @sample_rate = rate.to_f

          @diffusers.each do |stage|
            stage.each do |c|
              c.sample_rate = rate unless c.sample_rate == @sample_rate
            end
          end

          self
        end

        # Generates and returns +count+ samples of the mixed dry and
        # reverberated signal.
        def sample(count)
          dry = @upstream_sampler.sample(count)

          fdn = @feedback_network.map { |c| c.sample(count) }

          # TODO: automatic ringdown time?
          return nil if dry.nil? || fdn.any?(&:nil?)

          # Householder matrix (reflection across a plane)
          MB::M.reflect(Vector[*fdn], @normal)

          fdn.each_with_index do |v, idx|
            @feedback[idx][0...v.length] = v
          end

          diffusion_gain = @stages * @channels * @channels

          wet = fdn.sum * (@wet / diffusion_gain)

          wet + dry * @dry
        end
      end
    end
  end
end
