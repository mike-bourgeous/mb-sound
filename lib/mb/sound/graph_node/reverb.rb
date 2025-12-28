module MB
  module Sound
    module GraphNode
      class Reverb
        include GraphNode
        include GraphNode::SampleRateHelper

        def initialize(upstream:, diffusion_channels:, stages:, diffusion_range:, feedback_range:, sample_rate:, wet:, dry:)
          @upstream = upstream
          @upstream_sampler = upstream.get_sampler
          @channels = Integer(diffusion_channels)
          @stages = Integer(stages)
          @diffusion_range = diffusion_range
          @feedback_range = feedback_range
          @sample_rate = sample_rate.to_f
          @wet = wet.to_f
          @dry = dry.to_f
          @feedback_gain = 0.5 # FIXME: adjust gain or use compression or something based on feedback gain

          # Create diffusers with delays evenly spaced across the range
          #
          # TODO: consider uneven spacing e.g. placing more near the start
          delay_span = @diffusion_range.end - @diffusion_range.begin
          last_stage = nil
          @diffusers = Array.new(@stages) do |idx|
            delay_begin = @diffusion_range.begin + delay_span * idx
            delay_end = delay_begin + delay_span
            delay_range = delay_begin..delay_end
            last_stage = make_diffuser(
              channels: @channels,
              delay_range: delay_range,
              input: last_stage || @upstream
            )
          end

          # Normal for reflection plane for Householder matrix, making sure
          # each dimension is nonzero
          @normal = Vector[*Array.new(@channels) { rand(0.01..1) * (rand > 0.5 ? 1 : -1) }].normalize

          @feedback = Array.new(@channels) { Numo::SFloat.zeros(48000) }
          @feedback_network = make_fdn(@diffusers.last)
        end

        # Creates and returns a single diffuser stage as an Array of GraphNodes
        # that will delay, shuffle, and remix the input(s).
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
              source = input.get_sampler
            end

            wet_gain = rand > 0.5 ? 1 : -1

            # Delay and inversion step (wet gain 1 or -1)
            source.delay(seconds: delay_time, wet: wet_gain, smoothing: false, max_delay: MB::M.max(delay_range.end, 1.0))
          end

          # Hadamard mixing step
          matrix = MB::Sound::GraphNode::MatrixMixer.new(matrix: hadamard, inputs: nodes, sample_rate: @sample_rate)
          matrix.outputs.shuffle
        end

        # Creates the feedback delay network, except for the mixing stage
        # (implemented in #sample).
        def make_fdn(inputs)
          inputs.map.with_index { |inp, idx|
            inp
              .proc { |v| v + @feedback[idx][0...v.length] }
              .delay(seconds: rand(@feedback_range), smoothing: false, max_delay: MB::M.max(@feedback_range.end, 1.0))
              .*(@feedback_gain)
          }
        end

        def sources
          { input: @upstream }
        end

        def sample_rate=(rate)
          @sample_rate = rate.to_f

          @diffusers.each do |stage|
            stage.each do |c|
              c.sample_rate = rate unless c.sample_rate == @sample_rate
            end
          end

          self
        end

        def sample(count)
          dry = @upstream_sampler.sample(count)

          fdn = @feedback_network.map { |c| c.sample(count) }

          return nil if dry.nil? || fdn.any?(&:nil?)

          # Householder matrix (reflection across a plane)
          MB::M.reflect(Vector[*fdn], @normal)

          fdn.each_with_index do |v, idx|
            @feedback[idx][0...v.length] = v
          end

          diffusion_gain = @stages * @channels * @channels
          fdn.sum * (@wet / diffusion_gain) + dry * @dry
        end
      end
    end
  end
end
