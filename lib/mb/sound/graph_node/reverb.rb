module MB
  module Sound
    module GraphNode
      class Reverb
        include GraphNode
        include GraphNode::SampleRateHelper

        def initialize(upstream:, diffusion_channels:, stages:, diffusion_range:, feedback_range:, sample_rate:)
          @upstream = upstream
          @channels = Integer(diffusion_channels)
          @stages = Integer(stages)
          @diffusion_range = diffusion_range
          @feedback_range = feedback_range
          @sample_rate = sample_rate.to_f

          # Create diffusers with delays evenly spaced across the range
          #
          # TODO: consider uneven spacing e.g. placing more near the start
          delay_span = @diffusion_range.end - @diffusion_range.begin
          last_stage = nil
          @diffusers = Array.new(stages) do |idx|
            delay_begin = @diffusion_range.begin + delay_span * idx
            delay_end = delay_begin + delay_span
            delay_range = delay_begin..delay_end
            last_stage = make_diffuser(
              channels: @channels,
              delay_range: delay_range,
              input: last_stage || @upstream
            )
          end
        end

        def make_diffuser(channels:, delay_range:, input:)
          delay_span = (delay_range.end - delay_range.begin).to_f / channels

          hadamard = MB::M.hadamard(channels).transpose.shuffle.transpose.shuffle

          nodes = Array.new(channels) do |idx|
            delay_begin = delay_range.begin + delay_span * idx
            delay_end = delay_begin + delay_span
            delay_time = rand(delay_begin..delay_end)

            puts "Delay: #{delay_time}" # XXX

            if input.is_a?(Array)
              source = input[idx]
            else
              source = input.get_sampler
            end

            wet_gain = rand > 0.5 ? 1 : -1

            # Delay and inversion step (wet gain 1 or -1)
            source.delay(seconds: delay_time, wet: wet_gain, smoothing: true, max_delay: MB::M.max(delay_range.end, 1.0))
          end

          # Hadamard mixing step
          # FIXME: glitches when channel count is greater than 1
          matrix = MB::Sound::GraphNode::MatrixMixer.new(matrix: hadamard, inputs: nodes, sample_rate: @sample_rate)
          matrix.outputs
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
          # Just add the channels from the last diffuser for now
          @diffusers.last.map.with_index { |c, idx|
            # puts "Sampling diffuser #{idx} #{c}" # XXX
            c.sample(count) # XXX .tap { |buf| puts "    Got #{buf.class}/#{buf.__id__}/#{buf.length}" } # XXX tap
          }.sum
        end
      end
    end
  end
end
