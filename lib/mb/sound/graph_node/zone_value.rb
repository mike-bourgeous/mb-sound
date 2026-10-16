module MB
  module Sound
    module GraphNode
      # The value of a Sampler::ZoneMap for the current note: each sample
      # reads the note +number+ and +velocity+ (0..1, as Notes#velocity)
      # inputs, rounds them to MIDI numbers like the sampler kernel's region
      # choice, and outputs the map's value for them.  Made by
      # Sampler::Instrument#play for SoundFont settings that change from zone
      # to zone (envelope times, sustain levels, filter cutoffs).
      #
      # ZoneValues of one voice share an Index (+index:+), which reads the
      # number and velocity once per buffer for all of them.
      #
      #     ZoneValue.new(map, number: v.number, velocity: v.velocity)
      #     idx = ZoneValue::Index.new(v.number, v.velocity)
      #     ZoneValue.new(map, index: idx)
      class ZoneValue
        include GraphNode
        include SampleRateHelper

        # The zone table indices (key × 128 + velocity) of a voice's notes,
        # read once per buffer for every ZoneValue sharing it: each reader
        # asks for its own next buffer, and the Index reads its inputs when
        # the first reader gets there (readers of one graph move in lockstep;
        # the last KEEP buffers are kept for readers sampled later in the
        # same pass).
        class Index
          KEEP = 4

          # The note number and velocity samplers (for graph traversal).
          attr_reader :number, :velocity

          def initialize(number, velocity)
            @number = number.get_sampler
            @velocity = velocity.get_sampler
            @results = {}
            @last = 0
          end

          # [constant index or nil, Int32 indices or nil] for buffer +n+
          # (1, 2, ...) of +count+ samples, or nil once the notes end.
          def read(n, count)
            return @results.fetch(n) if @results.key?(n)
            raise ArgumentError, "ZoneValue::Index: buffer #{n} was asked for after buffer #{@last} (readers out of step)" unless n == @last + 1

            @last = n
            @results.delete(n - KEEP)
            @results[n] = compute(count)
          end

          private

          def compute(count)
            num = @number.sample(count)
            return nil if num.nil?
            count = num.length
            vel = @velocity.sample(count)
            return nil if vel.nil?
            vel = vel[0...count] if vel.length > count

            # The usual case: one note (or none) for the whole buffer (ptp
            # is the cheapest whole-buffer check measured)
            if num[0] == num[-1] && vel[0] == vel[-1] && num.ptp == 0 && vel.ptp == 0
              return [ZoneValue.index(num[0], vel[0]), nil, count].freeze
            end

            keys = Numo::Int32.cast((Numo::DFloat.cast(num) + 0.5).floor.clip(0, 127))
            vels = Numo::Int32.cast((Numo::DFloat.cast(vel) * 127.0 + 0.5).floor.clip(0, 127))
            [nil, (keys * 128 + vels).freeze, count].freeze
          end
        end

        # The table index for note number +n+ and velocity +v+ (0..1), rounded
        # like the kernel's region choice.
        def self.index(n, v)
          (n.to_f + 0.5).floor.clamp(0, 127) * 128 + (v.to_f * 127.0 + 0.5).floor.clamp(0, 127)
        end

        # The Sampler::ZoneMap read.
        attr_reader :map

        def initialize(map, number: nil, velocity: nil, index: nil, sample_rate: 48000)
          raise ArgumentError, "A ZoneValue reads a Sampler::ZoneMap (got #{map.inspect})" unless map.is_a?(Sampler::ZoneMap)
          raise ArgumentError, 'Give a ZoneValue number: and velocity:, or an index:' unless index || (number && velocity)
          @map = map
          @table = map.table.reshape(128 * 128)
          @values = @table.to_a.freeze
          @constant = nil
          @index = index || Index.new(number, velocity)
          @reads = 0
          @sample_rate = sample_rate.to_f
          @buf = nil
          @node_type_name = 'Zone Value'
        end

        def sample(count)
          r = @index.read(@reads += 1, count)
          return nil if r.nil?
          const, indices, count = r

          if @buf.nil? || @buf.length != count
            @buf = Numo::SFloat.zeros(count)
            @constant = nil
          end

          if const
            # the buffer already holds this value after the first time
            x = @values[const]
            unless @constant == x
              @buf.fill(x)
              @constant = x
            end
          else
            @buf[0..] = @table[indices]
            @constant = nil
          end
          @buf
        end

        def sources
          { number: @index.number, velocity: @index.velocity }
        end

        def plan_unsupported_reason
          'zone values are a plan boundary for now'
        end

        def to_s
          "ZoneValue #{@map}"
        end
      end
    end
  end
end
