module MB
  module Sound
    module Drums
      # A drum machine kit: the mixed sum of its Voices (see Drums).  Ends
      # when every voice has ended (see Voice; never for looping clips or
      # live MIDI).  Index it by voice name for single voices, e.g. to
      # process the kick separately:
      #
      #     kit = tr808(grid(16, kick: 'x...x...', hat: 'x.x.x.x.').loop)
      #     kit[:kick]     # the kick Voice (also part of the mix)
      #     kit.voices     # { kick: Voice, closed_hat: Voice }
      class Kit
        include GraphNode

        # The machine name (e.g. :tr808).
        attr_reader :machine

        # The voices by name (a frozen Hash).
        attr_reader :voices

        def initialize(voices, machine:, sample_rate: 48000)
          raise ArgumentError, 'A drum kit needs at least one voice' if voices.empty?

          @voices = voices.dup.freeze
          @samplers = @voices.transform_values(&:get_sampler)
          @machine = machine
          @sample_rate = sample_rate.to_f
          @buf = nil
          @node_type_name = "#{machine} kit"
        end

        # The voice named +name+.
        def [](name)
          @voices.fetch(name) { raise KeyError, "No #{@machine} voice #{name.inspect} in this kit (voices: #{@voices.keys.map(&:inspect).join(', ')})" }
        end

        # The voice names.
        def names
          @voices.keys
        end

        def sample(count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf.fill(0)

          any = false
          @samplers.each_value do |s|
            data = s.sample(count)
            next if data.nil? || data.empty?

            any = true
            if data.length == count
              @buf.inplace + data
            else
              @buf[0...data.length] = @buf[0...data.length] + data
            end
          end

          any ? @buf : nil
        end

        # True once every voice has ended.
        def ended?
          @voices.each_value.all?(&:ended?)
        end

        attr_reader :sample_rate

        def sample_rate=(rate)
          @voices.each_value { |v| v.sample_rate = rate }
          @sample_rate = rate.to_f
          self
        end

        def sources
          @samplers.dup
        end

        def to_s
          "#{@machine} kit (#{@voices.keys.join(', ')})"
        end
      end
    end
  end
end
