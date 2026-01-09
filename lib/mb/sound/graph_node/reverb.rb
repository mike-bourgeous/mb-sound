module MB
  module Sound
    module GraphNode
      # An artificial reverberation algorithm based on a presentation by
      # Geraint Luff at ADC21.  The basic algorithm is a number of
      # delay-and-mix diffusion steps followed by a feedback delay network.
      #
      # Reference video: https://www.youtube.com/watch?v=6ZK2Goiyotk
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
        # +:channels+ - The number of parallel paths for diffusion and
        #               feedback.  Higher means more diffusion but more CPU
        #               usage.  Must be a power of two; try 4 to 16.
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
        # +:seed+ - Random seed Integer for reproducibility of random delays.
        #           Try different seeds if you get unwanted ringing or echo.
        def initialize(upstream:, channels:, stages:, diffusion_range:, feedback_range:, feedback_gain:, sample_rate:, wet:, dry:, seed:)
          @sample_rate = sample_rate.to_f
          @upstream = upstream
          check_rate(@upstream, 'upstream')

          @upstream_sampler = upstream.get_sampler.named('Reverb upstream')
          @channels = Integer(channels)
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
          # FIXME: must be a memory leak or very excessive allocation or something as the reverb eventually starts skipping
          # TODO: stereo or multichannel output based on channel subset mixing
          # stereo/mchannel reverb could just take every nth output and ignore or share the remainders, or could use a downmix matrix
          # TODO: stereo or multichannel input
          # TODO: infinite reverb where feedback loop is normalized and
          # feedback gain is proportional to input volume from diffusion stage
          # TODO: filters in line with feedback to create variable decay times
          # TODO: modulate delay times for richer sound
          # TODO: realtime/MIDI parameter control
          # FIXME: risk of very low or high frequency oscillation ; put
          # high/low pass filter on output or feedback path

          @random = Random.new(seed)

          # Create diffusers with delays evenly spaced across the range
          # TODO: consider uneven spacing e.g. placing more near the start
          delay_span = @diffusion_range.end - @diffusion_range.begin
          last_stage = nil
          puts "\e[1mOverall diffuser delay series\e[0m"
          delays = delay_series(count: @stages, max: delay_span)
          @diffusers = Array.new(@stages) do |idx|
          puts "\e[1m  Diffuser #{idx}\e[0m"
            delay_end = @diffusion_range.begin + delay_span * (idx + 1)
            delay_range = 0..delay_end
            last_stage = make_diffuser(
              channels: @channels,
              delay_range: @diffusion_range.begin..(delays[idx] + delay_span),
              input: last_stage || @upstream,
              stage: idx
            )
          end

          # Normal for reflection plane for Householder matrix, making sure
          # each dimension is nonzero
          @normal = Vector[*Array.new(@channels) { |c| @random.rand((c * 0.5 / @channels)..1) * (@random.rand > 0.5 ? 1 : -1) }].normalize

          puts "\e[1mFDN delay series\e[0m"
          @feedback = Array.new(@channels) { Numo::SFloat.zeros(48000) }
          @feedback_network = make_fdn(@diffusers.last)
        end

        # For internal use.  Creates and returns a single diffuser stage as an
        # Array of GraphNodes that will delay, shuffle, and remix the input(s).
        def make_diffuser(stage:, channels:, delay_range:, input:)
          puts "  Dif #{stage} range #{delay_range}" # XXX
          delay_span = (delay_range.end - delay_range.begin).to_f
          delays = delay_series(count: channels, max: delay_span).shuffle

          hadamard = MB::M.hadamard(channels)

          nodes = Array.new(channels) do |idx|
            delay_time = delays[idx] + delay_range.begin
            puts "Diffusion stage #{stage} channel #{idx} delay = #{delay_time}"

            if input.is_a?(Array)
              source = input[idx]
            else
              source = input.get_sampler.named("Reverb diffusion stage #{stage + 1} #{idx + 1}")
            end

            wet_gain = @random.rand > 0.5 ? 1 : -1

            # Delay and inversion step (wet gain 1 or -1)
            source.delay(seconds: delay_time, wet: wet_gain, smoothing: false, max_delay: MB::M.max(delay_range.end + 0.2, 1.0))
          end

          # Hadamard mixing step
          matrix = MB::Sound::GraphNode::MatrixMixer.new(matrix: hadamard, inputs: nodes, sample_rate: @sample_rate)
          matrix.outputs.shuffle
        end

        # For internal use.  Creates the feedback delay network, minus the
        # mixing stage (implemented in #sample).
        def make_fdn(inputs)
          delay_span = @feedback_range.end - @feedback_range.begin
          delays = delay_series(count: inputs.length, max: delay_span).shuffle

          inputs.map.with_index { |inp, idx|
            delay_time = delays[idx] + @feedback_range.begin

            puts "Feedback #{idx} delay = #{delay_time}" # XXX
            # TODO: adding a dry: to the .delay would basically be an early return
            inp
              .proc { |v| v + @feedback[idx][0...v.length].inplace * @feedback_gain }
              .delay(seconds: delay_time, smoothing: false, max_delay: MB::M.max(@feedback_range.end + 0.2, 1.0))
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

        # Returns a series of randomly spaced delay times, ensuring a
        # relatively even spread.
        def delay_series(count:, max:)
          chunk_min = 0
          chunk_size = max.to_f / count
          chunk_max = chunk_size

          Array.new(count) do |i|
            @random.rand(chunk_min..chunk_max).tap { |v|
              puts "DLY #{v} min=#{chunk_min} max=#{chunk_max}" # XXX
              chunk_min = v
              chunk_max += chunk_size
            }
          end.tap { |series| # XXX
            puts "Delay series: count=#{count} max=#{max} delays=#{series.join(', ')}" # XXX
          }
        end
      end
    end
  end
end
