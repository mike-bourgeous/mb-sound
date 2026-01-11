require 'set'

module MB
  module Sound
    module GraphNode
      # An artificial reverberation algorithm based on a presentation by
      # Geraint Luff at ADC21.  The basic algorithm is a number of
      # delay-and-mix diffusion steps followed by a feedback delay network.
      #
      # Reference video: https://www.youtube.com/watch?v=6ZK2Goiyotk
      #
      # This is structurally similar to a Schroeder reverb (see
      # https://ccrma.stanford.edu/~jos/pasp/Schroeder_Reverberators.html).
      #
      # See MB::Sound::GraphNode#reverb for a starting point for parameters, as
      # it's easy to make something that sounds bad.
      #
      # Example (bin/sound.rb):
      #     play file_input('sounds/drums.flac').reverb
      class Reverb
        include GraphNode
        include GraphNode::SampleRateHelper
        include MultiOutput

        # Some known-reasonable parameters for the reverb algorithm (plus an
        # extra_time value for roughly how long it takes for the reverb to ring
        # out).
        PRESETS = {
          room: {
            description: 'Subtle in-room reverb',
            channels: 8,
            stages: 4,
            diffusion_range: 0.01,
            feedback_range: 0.003..0.016,
            feedback_gain: 0.45,
            predelay: 0,
            dry: 1,
            wet: -16.db,
            seed: 0,
            extra_time: 1,
          },
          hall: {
            description: 'Something like a symphony hall',
            channels: 8,
            stages: 4,
            diffusion_range: 0.05,
            feedback_range: 0.03..0.14,
            feedback_gain: 0.9,
            predelay: 0,
            dry: 1,
            wet: -20.db,
            seed: 5,
            extra_time: 6,
          },
          stadium: {
            description: 'Stadium PA echo',
            channels: 4,
            stages: 3,
            diffusion_range: 0.05,
            feedback_range: 0.3..0.45,
            feedback_gain: -4.db,
            predelay: 0,
            dry: 1,
            wet: -6.db,
            seed: 13,
            extra_time: 8,
          },
          space: {
            description: 'Outer space, dreaming',
            chanels: 16,
            stages: 4,
            diffusion_range: 0.06,
            feedback_range: 0.2,
            feedback_gain: 0.97,
            predelay: 0.01,
            dry: 1,
            wet: -4.5.db,
            seed: 0,
            extra_time: 36,
          },
          default: {
            channels: 8,
            stages: 4,
            diffusion_range: 0.0005..0.01,
            feedback_range: 0.1,
            feedback_gain: -6.db,
            predelay: 0,
            dry: 1,
            wet: 1,
            seed: 0,
            extra_time: 2,
          },
        }

        # For internal use by Reverb.  Represents a single output on a stereo
        # or multi-channel reverb.
        # TODO: consolidate supporting code for multi-output graph nodes.
        class ReverbOutput
          extend Forwardable
          include GraphNode
          include NodeOutput

          def_delegators :@reverb, :sample_rate, :sample_rate=, :at_rate

          # Creates an output handle for channel +:index+ (0-based) on the
          # given +:reverb+.
          def initialize(reverb:, index:)
            @reverb = reverb
            @index = index
          end

          # Returns the next +count+ samples for this output channel.  Call
          # each channel only once per graph iteration.  GraphNode#get_sampler
          # helps here.
          def sample(count)
            @reverb.sample_internal(count, index: @index)
          end

          def sources
            { reverb: @reverb }
          end

          def to_s
            "Reverb output #{@index} of #{@reverb.output_channels}"
          end
        end

        # A Hash with the parameters of this Reverb.
        # TODO: somehow incorporate MIDI-controllable or realtime-controllable parameters
        attr_reader :parameters

        attr_reader :output_channels, :outputs

        # Initializes a reverb node with the given parameters.  See
        # PRESETS for some example defaults.  Generally one would use
        # GraphNode#reverb to create a reverb.
        #
        # If +:upstream+ is a MultiOutput node, then it will split out all of
        # the outputs from that node as a multichannel input.
        #
        # +:upstream+ - The source node to which to apply reverb, or an Array
        #               of source nodes.
        # +:channels+ - The number of parallel paths for diffusion and
        #               feedback.  Higher means more diffusion but more CPU
        #               usage.  Must be a power of two; try 4 to 16.
        # +:output_channels+ - The number of output channels to create.
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
        # +:predelay+ - The wet signal is delayed by this amount.  Default 0.
        # +:wet+ - The reverberated signal output level.  Usually 1.0.
        # +:dry+ - The original signal output level.  Usually 1.0.
        # +:seed+ - Random seed Integer for reproducibility of random delays.
        #           Try different seeds if you get unwanted ringing or echo.
        def initialize(upstream:, channels:, output_channels:, stages:, diffusion_range:, feedback_range:, feedback_gain:, predelay:, wet:, dry:, seed:, sample_rate:)
          @random = Random.new(seed)

          @sample_rate = sample_rate.to_f

          @upstreams = upstream
          @upstreams = @upstreams.outputs if @upstreams.is_a?(MB::Sound::GraphNode::MultiOutput)
          @upstreams = [@upstreams] unless @upstreams.is_a?(Array)

          @upstreams.each_with_index do |u, idx|
            check_rate(@upstreams, "upstream #{idx}")
          end
          @upstream_samplers = @upstreams.map.with_index { |u, idx|
            u.get_sampler.named("Reverb #{__id__} upstream #{idx}")
          }

          @channels = Integer(channels)
          @output_channels = Integer(output_channels)
          @stages = Integer(stages)

          raise 'Channels must be positive' unless @channels >= 1
          raise 'Channels must be a power of two' unless @channels == (2 ** Math.log2(@channels).floor).round
          raise 'Stages must be positive' unless @stages >= 1
          raise 'Output channels must be positive' unless @output_channels >= 1

          diffusion_range = 0..diffusion_range.to_f if diffusion_range.is_a?(Numeric)
          @diffusion_range = diffusion_range

          feedback_range = 0..feedback_range.to_f if feedback_range.is_a?(Numeric)
          @feedback_range = feedback_range

          @wet = wet.to_f
          @dry = dry.to_f
          @feedback_gain = feedback_gain.to_f

          @predelay = predelay.to_f

          if @output_channels > 1
            @outputs = Array.new(@output_channels) do |idx|
              ReverbOutput.new(reverb: self, index: idx)
            end.freeze
          else
            @outputs = [self].freeze
          end

          @parameters = {
            channels: @channels,
            output_channels: @output_channels,
            stages: @stages,
            diffusion_range: @diffusion_range,
            feedback_range: @feedback_range,
            feedback_gain: @feedback_gain.to_db,
            wet: @wet.to_db,
            dry: @dry.to_db,
            seed: seed,
          }.freeze

          # FIXME: must be a memory leak or very excessive allocation or something as the reverb eventually starts skipping
          # TODO: infinite reverb where feedback loop is normalized and
          # feedback gain is proportional to input volume from diffusion stage
          # TODO: filters in line with feedback to create variable decay times
          # TODO: modulate delay times for richer sound
          # TODO: realtime/MIDI parameter control
          # FIXME: risk of very low or high frequency oscillation ; put
          # high/low pass filter on output or feedback path
          # TODO: downmix matrix for multichannel outputs?
          # TODO: could do more complex designs for multichannel input with
          # independent or semi-independent diffusion stages, as the current
          # diffusion stage pretty fully mixes all input channels

          # Create diffusers with delays evenly spaced across the range
          # TODO: consider uneven spacing e.g. placing more near the start
          delay_span = @diffusion_range.end - @diffusion_range.begin
          last_stage = nil
          delays = delay_series(count: @stages, max: delay_span)

          @upstream_groups = partition_outputs(@upstreams, @channels)
          pre_delayed = @upstream_groups.map { |u|
            u = u.length > 1 ? u.sum : u[0]
            u.delay(seconds: @predelay)
          }

          @diffusers = Array.new(@stages) do |idx|
            delay_end = @diffusion_range.begin + delay_span * (idx + 1)
            delay_range = 0..delay_end
            last_stage = make_diffuser(
              channels: @channels,
              delay_range: @diffusion_range.begin..(delays[idx] + delay_span),
              input: last_stage || pre_delayed,
              stage: idx
            )
          end

          # Normal for reflection plane for Householder matrix, making sure
          # each dimension is nonzero
          @normal = Vector[*Array.new(@channels) { |c| @random.rand((c * 0.5 / @channels)..1) * (@random.rand > 0.5 ? 1 : -1) }].normalize

          @feedback = Array.new(@channels) { Numo::SFloat.zeros(48000) }
          @feedback_network = make_fdn(@diffusers.last)

          # This gets overwritten on every call to #update
          @fdn_groups = partition_outputs(Array.new(@channels), @output_channels)

          # FIXME: adjust gain or use compression or something based on feedback gain
          # FIXME: gain based on number of stages is wrong
          @diffusion_gain = 1.0 / (@stages * @channels * @fdn_groups[0].length)

          @sampled_set = Set.new(0...@output_channels)
          @dry_output = nil
          @fdn_output = nil
        end

        # For internal use.  Creates and returns a single diffuser stage as an
        # Array of GraphNodes that will delay, shuffle, and remix the input(s).
        def make_diffuser(stage:, channels:, delay_range:, input:)
          delay_span = (delay_range.end - delay_range.begin).to_f
          delays = delay_series(count: channels, max: delay_span).shuffle

          hadamard = MB::M.hadamard(channels)

          nodes = Array.new(channels) do |idx|
            delay_time = delays[idx] + delay_range.begin

            if input.is_a?(Array)
              source = input[idx]
            else
              source = input.get_sampler.named("Reverb #{__id__} diffusion stage upstream #{stage + 1} #{idx + 1}")
            end

            diffuser_polarity = @random.rand > 0.5 ? 1 : -1

            # Delay and inversion step (wet gain 1 or -1)
            source
              .delay(seconds: delay_time, wet: diffuser_polarity, smoothing: false, max_delay: MB::M.max(delay_range.end + 0.2, 1.0))
              .named("Reverb #{__id__} diffusion delay #{stage + 1} #{idx + 1}")
          end

          # Hadamard mixing step
          matrix = MB::Sound::GraphNode::MatrixMixer.new(matrix: hadamard, inputs: nodes, sample_rate: @sample_rate)
          matrix.outputs.shuffle
        end

        # For internal use.  Creates the feedback delay network, minus the
        # mixing and reflection stage (implemented in #sample).
        def make_fdn(inputs)
          delay_span = @feedback_range.end - @feedback_range.begin
          delays = delay_series(count: inputs.length, max: delay_span).shuffle

          inputs.map.with_index { |inp, idx|
            delay_time = delays[idx] + @feedback_range.begin

            # TODO: adding a dry: to the .delay would basically be an early return
            inp
              .proc { |v| (@feedback[idx][0...v.length].inplace * @feedback_gain + v).not_inplace! }
              .delay(seconds: delay_time, smoothing: false, max_delay: MB::M.max(@feedback_range.end + 0.2, 1.0))
              .named("Reverb #{__id__} feedback delay #{idx + 1}")
          }
        end

        # Returns the input source, and if +:internal+ is true, the feedback
        # and diffusion network.
        def sources(internal: false)
          {
            **@upstream_samplers.map.with_index { |u, idx|
              ["input_#{idx + 1}", u]
            }.to_h,
            **(internal ? @feedback_network.map.with_index { |v, idx| [:"channel_#{idx + 1}", v] }.to_h : {})
          }
        end

        # Sets the sample rate of the upstream source and internal components.
        def sample_rate=(rate)
          @sample_rate = rate.to_f

          @diffusers.each do |stage|
            stage.each do |c|
              c.sample_rate = @sample_rate unless c.sample_rate == @sample_rate
            end
          end

          @feedback_network.each do |c|
            c.sample_rate = @sample_rate unless c.sample_rate == @sample_rate
          end

          self
        end

        # For internal use.  Generates the next +count+ samples without
        # downmixing and updates the feedback buffer.
        def update(count)
          dry = @upstream_samplers.map { |u| u.sample(count) }

          fdn = @feedback_network.map { |c| c.sample(count) }
          if dry.nil? || fdn.any?(&:nil?)
            @fdn_output = fdn
            @dry_output = nil
            return
          end

          # Householder matrix (reflection across a plane)
          refl = MB::M.reflect(Vector[*fdn], @normal).to_a

          # Store feedback for next iteration
          refl.each_with_index do |v, idx|
            @feedback[idx][0...v.length] = v if v
          end

          @fdn_output = refl
          @fdn_groups = partition_outputs(@fdn_output, @output_channels)

          @dry_output = dry.map { |c| (c.inplace * @dry).not_inplace! }
          @dry_groups = partition_outputs(@dry_output, @output_channels)
        end

        # For internal use by ReverbOutput#sample.
        def sample_internal(count, index:)
          if @sampled_set.include?(index)
            if @sampled_set.length != @output_channels
              warn "Output #{index} sampled again before all others sampled.  Sampled so far: #{@sampled_set}"
            end
            @sampled_set.clear
            update(count)
          end

          @sampled_set << index

          return nil if @dry_output.nil? || @fdn_output.any?(&:nil?)

          wet = @fdn_groups[index].sum * (@wet * @diffusion_gain)
          (wet.inplace + @dry_groups[index].sum).not_inplace!
        end

        # Generates and returns +count+ samples of the mixed dry and
        # reverberated signal.
        def sample(count)
          raise 'This is a multi-output Reverb.  Call #sample on one of the output objects.' if @output_channels != 1

          update(count)

          # TODO: automatic ringdown time?
          return nil if @dry_output.nil? || @fdn_output.any?(&:nil?)

          wet = @fdn_output.sum * (@wet * @diffusion_gain)
          (wet.inplace + @dry_output.sum).not_inplace!
        end

        # Returns a series of randomly spaced delay times, ensuring a
        # relatively even spread.
        def delay_series(count:, max:)
          chunk_min = 0
          chunk_size = max.to_f / count
          chunk_max = chunk_size

          Array.new(count) do |i|
            @random.rand(chunk_min..chunk_max).tap { |v|
              chunk_min = v
              chunk_max += chunk_size
            }
          end
        end

        private

        # Partitions the +list+ of objects into +count+ groups of equal size,
        # with leftovers shared across all list members.
        #
        # If +count+ is greater than the list length, then the operation is
        # basically inverted.  The list will be repeated until +count+ - 1
        # elements are reached, with the last group taking the remainder of the
        # list.  This ensures that all list elements appear the same number of
        # times.
        #
        # TODO: more complex / spatial aware mixing matrices?
        #
        # Example:
        #     partition_outputs([1, 2, 3, 4, 5], 2)
        #     # => [[1, 3, 5], [2, 4, 5]]
        #
        #     partition_outputs([1, 2], 3)
        #     # => [[1], [2], [1, 2]]
        #
        #     partition_outputs([1, 2, 3], 5)
        #     # => [[1], [2], [3], [1], [2, 3]]
        def partition_outputs(list, count)
          if count > list.length
            return Array.new(count) { |idx|
              if idx == count - 1
                # Take the remaining list elements to make sure every list
                # element occurs the same number of times
                list[(idx % list.length)..]
              else
                [list[idx % list.length]]
              end
            }
          end

          sliced = list.each_slice(count).to_a

          if sliced.last.length != count
            leftovers = sliced.pop
          end

          groups = sliced.transpose
          leftovers&.each do |l|
            groups.each do |g|
              g << l
            end
          end

          groups
        end
      end
    end
  end
end
