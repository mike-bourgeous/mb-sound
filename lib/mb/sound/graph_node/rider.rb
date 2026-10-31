module MB
  module Sound
    module GraphNode
      # A slow loudness rider (mastering-1): multiplies its input channels by
      # one gain that moves toward +target+ (LUFS) minus the input's
      # short-term loudness (ITU-R BS.1770 K-weighting, the last 3 s), like a
      # mastering engineer riding a fader into a limiter.  Created with
      # GraphNode#ride, and by mastering presets with +ride: true+ (see
      # Mastering).
      #
      # The gain is decided every 100 ms of the rider's own time (on a grid
      # counted from its first sample, so the output is the same at any
      # buffer size) from the 3 s of input before that moment, and ramps
      # there linearly over the next 100 ms.  It falls over +down+ seconds
      # (a time constant) when the program gets louder and rises over +up+
      # when it gets quieter, stays within +range+ of +start+, and holds
      # while the input is more than +gate+ LU under the loudest it has
      # been lately (a peak of the short-term loudness that falls DECAY LU
      # per second) or below -70 LUFS, so silence, fades, and breakdowns
      # aren't pumped up.
      #
      # It is a Channels bundle of outputs, like a LoudnessMeter: sample
      # every output once per buffer.
      #
      #     mix.ride(-14)                                 # into a limiter: .limit(ceiling: -1.db)
      #     mix.ride(-9, start: 6.db, range: 6.db, down: 2, up: 8)
      class Rider < Channels
        node_traits memory: :short, fresh: 'a loudness rider\'s seconds of measurement (not moved yet)'

        # One output of a Rider.
        class Output
          include GraphNode
          include GraphNode::NodeOutput
          node_traits memory: :none

          # The index of this output.
          attr_reader :index

          def initialize(rider:, index:, input:)
            @owner = rider
            @index = index
            @input = input
            @node_type_name = 'Rider'
          end

          def sample(count)
            @owner.sample_internal(count, @index)
          end

          # The Rider this output belongs to.
          def owner_rider
            @owner
          end

          def sample_rate
            @owner.sample_rate
          end

          def sources
            { input: @input }
          end

          def to_s
            "Rider output #{@index + 1} of #{@owner.channel_count}"
          end
        end

        # Seconds between gain decisions (and the length of each ramp).
        STEP = 0.1

        # How fast the gate's reference (the recent loudest short-term
        # loudness) falls, LU per second: 10 LU in 20 s, so a breakdown
        # holds the gain for its first 20 s or so, and a song that settles
        # quieter is followed after that.
        DECAY = 0.5

        # The target loudness (LUFS).
        attr_reader :target

        # The gain decided last (dB; the ramp reaches it within STEP).
        attr_reader :gain

        # The gain range (dB, [lowest, highest]).
        attr_reader :limits

        # Rides +inputs+ (nodes or bundles, one channel each per output)
        # toward +target+ LUFS.  +start+ is the first gain (Decibels or
        # linear), +range+ how far it may move from there (Decibels, either
        # way), +down+ and +up+ the time constants (seconds) for falling and
        # rising, +gate+ the LU under the recent loudest program below which
        # it holds.
        def initialize(inputs, target:, start: 0.db, range: 9.db, down: 3.0, up: 10.0, gate: 10.0)
          inputs = Array(inputs).flat_map { |n|
            raise ArgumentError, "Rider inputs must be graph nodes (got #{n.class})" unless n.is_a?(GraphNode) || n.is_a?(MultiOutput)
            n.outputs
          }
          raise ArgumentError, 'A rider needs at least one channel' if inputs.empty?
          raise ArgumentError, "ride target must be a number of LUFS (got #{target.inspect})" unless target.is_a?(Numeric) && target.real?
          raise ArgumentError, "ride times must be positive (down: #{down.inspect}, up: #{up.inspect})" unless down.to_f > 0 && up.to_f > 0

          @inputs = inputs.map(&:get_sampler)
          @target = target.to_f
          start_db = Decibels.db_of(start, 'start')
          span = Decibels.db_of(range, 'range').abs
          @limits = [start_db - span, start_db + span].freeze
          @down = down.to_f
          @up = up.to_f
          @gate = gate.to_f
          @program = -Float::INFINITY
          @sample_rate = @inputs[0].sample_rate.to_f
          @weights = Loudness.default_weights(@inputs.length)
          @filters = Array.new(@inputs.length) { Loudness.k_weighting(@sample_rate) }

          # Measurement: 10 ms segments (filled sample by sample, so their
          # sums don't depend on buffer boundaries) and the last 3 s of sums
          @segment = Numo::DFloat.zeros(segment_length(0))
          @segment_fill = 0
          @segments = 0
          @sums = []
          @per_step = (STEP / Loudness::SEGMENT).round

          # The gain: decided at @ramp_start (an absolute sample), ramping
          # from @from_gain to @to_gain over @ramp_length samples
          @gain = start_db
          @to_gain = 10.0 ** (start_db / 20.0)
          @from_gain = @to_gain
          @ramp_start = 0
          @ramp_length = 1
          @position = 0

          @sampled = Array.new(@inputs.length, false)
          @data = nil
          @out = nil

          super(@inputs.each_with_index.map { |input, idx| Output.new(rider: self, index: idx, input: input) })
        end

        def sample_rate
          @sample_rate
        end

        # The current linear gain (where the ramp is now).
        def linear_gain
          gain_at(@position)
        end

        def inspect
          "#<Rider #{channel_count} channels to #{format('%.1f', @target)} LUFS, gain #{format('%+.1f', @gain)} dB>"
        end

        def to_s_graphviz
          "#{graph_node_name || 'Rider'}\n#{format('%.1f', @target)} LUFS"
        end

        # Called by the outputs: processes every input when output +index+
        # starts a new frame and returns that channel's ridden buffer (nil
        # once every input has ended).
        def sample_internal(count, index)
          if @sampled[index] || @data.nil?
            if @sampled.any? && !@sampled.all?
              warn "#{self.class.name} output #{index} sampled again before the other outputs"
            end
            @sampled.fill(false)
            @data = @inputs.map { |i| i.sample(count) }
            @out = process(@data)
          end

          @sampled[index] = true
          @out && @out[index]
        end

        private

        # Samples in 10 ms segment +k+ (rounded like Loudness::Analyzer).
        def segment_length(k)
          ((k + 1) * @sample_rate * Loudness::SEGMENT).round - (k * @sample_rate * Loudness::SEGMENT).round
        end

        # The linear gain at absolute sample +i+ (a function of +i+ alone, so
        # buffer sizes don't matter).
        def gain_at(i)
          t = i - @ramp_start
          return @to_gain if t >= @ramp_length
          @from_gain + (@to_gain - @from_gain) * (t + 1) / @ramp_length
        end

        # Rides one buffer per channel.
        def process(data)
          live = data.compact
          return nil if live.empty?
          n = live.map(&:length).min
          data = data.map { |d| d ? d[0...n] : Numo::SFloat.zeros(n) }

          # K-weighted, channel-weighted mean square per sample
          z = nil
          data.each_with_index do |d, c|
            next if @weights[c] == 0
            shelf, highpass = @filters[c]
            y = highpass.process(shelf.process(Numo::DFloat.cast(d)))
            sq = y * y
            sq = sq * @weights[c] if @weights[c] != 1
            z = z ? z + sq : sq
          end
          z ||= Numo::DFloat.zeros(n)

          gains = Numo::SFloat.zeros(n)
          pos = 0
          while pos < n
            take = [@segment.length - @segment_fill, n - pos].min
            @segment[@segment_fill...(@segment_fill + take)] = z[pos...(pos + take)]
            fill_gains(gains, pos, take)
            @segment_fill += take
            pos += take
            @position += take
            finish_segment if @segment_fill == @segment.length
          end

          data.map { |d| d * gains }
        end

        # Writes the gains for +take+ samples from +pos+ into +gains+.
        def fill_gains(gains, pos, take)
          first = @position
          last = @position + take - 1
          if first - @ramp_start >= @ramp_length
            gains[pos...(pos + take)] = @to_gain
          else
            idx = Numo::DFloat.new(take).seq(first - @ramp_start + 1)
            ramp = (@from_gain + (@to_gain - @from_gain) * idx.clip(0, @ramp_length) / @ramp_length)
            gains[pos...(pos + take)] = ramp
          end
          last
        end

        # Closes a 10 ms segment and, every STEP, decides the next gain.
        def finish_segment
          @sums << @segment.sum
          @sums.shift if @sums.length > Loudness::SHORT_TERM_SEGMENTS
          @segments += 1
          @segment = Numo::DFloat.zeros(segment_length(@segments))
          @segment_fill = 0
          decide if @segments % @per_step == 0
        end

        # Moves the gain toward the target from the last 3 s (silence before
        # the start), or holds it (see the class comment).
        def decide
          energy = @sums.sum / (Loudness::SHORT_TERM_SEGMENTS * @sample_rate * Loudness::SEGMENT)
          loudness = Loudness.lufs(energy)
          current = @gain
          @program = [loudness, @program - DECAY * STEP].max if loudness.finite? && loudness > -70
          if loudness.finite? && loudness > -70 && loudness >= @program - @gate
            wanted = (@target - loudness).clamp(*@limits)
            tau = wanted < current ? @down : @up
            @gain = current + (wanted - current) * (1 - Math.exp(-STEP / tau))
          end

          @from_gain = gain_at(@position - 1)
          @to_gain = 10.0 ** (@gain / 20.0)
          @ramp_start = @position
          @ramp_length = [(STEP * @sample_rate).round, 1].max
        end
      end
    end
  end
end
