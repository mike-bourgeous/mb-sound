module MB
  module Sound
    module GraphNode
      # A live ITU-R BS.1770 loudness meter: passes its input channels
      # through unchanged and measures them together (one Loudness::Analyzer
      # for every channel, weighted as in Loudness.default_weights), updated
      # every buffer.  Read #momentary (400 ms), #short_term (3 s),
      # #integrated, #range, and #true_peak at any time, e.g. from the
      # console while it plays, or from a UI.
      #
      # It is a Channels bundle of pass-through outputs, so it plays and
      # chains like any bundle.  Sample every output once per buffer, as a
      # Session does (like mixers, the meter reads all of its inputs when an
      # output is sampled again).
      #
      # Created with GraphNode#loudness_meter (alias #lufs_meter).
      #
      # Examples (bin/sound.rb):
      #     m = 110.hz.ramp.filter(:lowpass, cutoff: 800).at(-12.db).loudness_meter
      #     bg m
      #     m.momentary     # => -21.3 (LUFS)
      #     m.to_s          # => "M -21.3  S -21.3  I -21.3 LUFS  LRA 0.0 LU  TP -12.0 dBTP"
      #
      #     m = file_input('song.flac').loudness_meter   # a stereo bundle
      #     bg m.softclip   # chain on as usual; the meter sees the input
      class LoudnessMeter < Channels
        # One pass-through output of a LoudnessMeter.
        class Output
          include GraphNode
          include GraphNode::NodeOutput

          # The index of this output.
          attr_reader :index

          def initialize(meter:, index:, input:)
            @owner = meter
            @index = index
            @input = input
            @node_type_name = 'LoudnessMeter'
          end

          # Returns this channel's input buffer, measured with the other
          # channels' buffers.
          def sample(count)
            @owner.sample_internal(count, @index)
          end

          def sample_rate
            @owner.sample_rate
          end

          # Sets the sample rate of the meter and its inputs (restarting the
          # measurement).
          def sample_rate=(rate)
            @owner.sample_rate = rate
            self
          end

          def sources
            { input: @input }
          end

          def to_s
            "LoudnessMeter output #{@index + 1} of #{@owner.channel_count}"
          end
        end

        # The Loudness::Analyzer with every measurement so far.
        attr_reader :analyzer

        # Measures +inputs+ (graph nodes or bundles, one channel each per
        # output).  +:weights+ and +:true_peak+ are as for
        # Loudness::Analyzer.
        def initialize(inputs, weights: nil, true_peak: true)
          inputs = Array(inputs).flat_map { |n|
            unless n.is_a?(GraphNode) || n.is_a?(MultiOutput)
              raise ArgumentError, "Loudness meter inputs must be graph nodes (got #{n.class})"
            end
            n.outputs
          }
          raise ArgumentError, 'A loudness meter needs at least one channel' if inputs.empty?

          @inputs = inputs.map(&:get_sampler)
          @weights = weights
          @true_peak = true_peak
          @sample_rate = @inputs[0].sample_rate.to_f
          @sampled = Array.new(@inputs.length, false)
          @data = nil
          reset

          super(@inputs.each_with_index.map { |input, idx| Output.new(meter: self, index: idx, input: input) })
        end

        def sample_rate
          @sample_rate
        end

        # Sets the sample rate of every input and restarts the measurement.
        def sample_rate=(rate)
          @inputs.each { |i| i.sample_rate = rate }
          @sample_rate = rate.to_f
          reset
        end
        alias at_rate sample_rate=

        # Starts a new measurement (integrated loudness, range, and peaks
        # start over).  Returns self.
        def reset
          @analyzer = Loudness::Analyzer.new(channels: @inputs.length, sample_rate: @sample_rate, weights: @weights, true_peak: @true_peak)
          self
        end

        # Momentary loudness (LUFS, last 400 ms).
        def momentary
          @analyzer.momentary
        end
        alias m momentary

        # Short-term loudness (LUFS, last 3 s).
        def short_term
          @analyzer.short_term
        end
        alias s short_term

        # Gated integrated loudness (LUFS) since the start or #reset.
        def integrated
          @analyzer.integrated
        end
        alias lufs integrated

        # Loudness range (LU) since the start or #reset.
        def range
          @analyzer.range
        end
        alias lra range

        # True peak (dBTP) since the start or #reset (nil with
        # +true_peak: false+).
        def true_peak
          @analyzer.true_peak
        end

        # Every measurement so far (a Loudness::Result).
        def result
          @analyzer.result
        end

        # The current readings as a Hash, for displays.
        def readings
          {
            momentary: momentary,
            short_term: short_term,
            integrated: integrated,
            range: range,
            true_peak: true_peak,
          }
        end

        # A one-line meter reading, e.g. "M -21.3  S -21.5  I -21.4 LUFS
        # LRA 1.2 LU  TP -3.0 dBTP".
        def to_s
          f = ->(v) { v.nil? ? 'n/a' : v.finite? ? format('%.1f', v) : '-inf' }
          r = readings
          "M #{f.(r[:momentary])}  S #{f.(r[:short_term])}  I #{f.(r[:integrated])} LUFS  " \
            "LRA #{f.(r[:range])} LU  TP #{f.(r[:true_peak])} dBTP"
        end

        def inspect
          "#<LoudnessMeter #{channel_count} channels: #{self}>"
        end

        def to_s_graphviz
          "#{graph_node_name || 'LoudnessMeter'}\n#{channel_count} channels"
        end

        # Called by the outputs: samples every input when output +index+
        # starts a new frame, measures the frame, and returns the input
        # buffer for +index+ (nil once that input has ended).
        def sample_internal(count, index)
          if @sampled[index] || @data.nil?
            if @sampled.any? && !@sampled.all?
              warn "#{self.class.name} output #{index} sampled again before the other outputs"
            end
            @sampled.fill(false)

            @data = @inputs.map { |i| i.sample(count) }
            live = @data.compact
            if live.length == @data.length
              @analyzer.process(@data)
            elsif !live.empty?
              # Ended channels count as silence while the others play on
              n = live.map(&:length).max
              @analyzer.process(@data.map { |d| d || Numo::SFloat.zeros(n) })
            end
          end

          @sampled[index] = true
          @data[index]
        end
      end
    end
  end
end
