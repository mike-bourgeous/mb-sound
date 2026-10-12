module MB
  module Sound
    module Structure
      # An output that keeps everything written to it in memory, so
      # StructureMethods#analyze_form can render a graph without a file.
      class Capture < NullOutput
        def initialize(channels: 2, sample_rate: 48000, buffer_size: 800)
          super(channels: channels, sample_rate: sample_rate, buffer_size: buffer_size, sleep: false)
          @chunks = Array.new(channels) { [] }
        end

        def write(data)
          super
          data.each_with_index { |c, i| @chunks[i] << Numo::SFloat.cast(c) }
        end

        # The audio written so far, as an Array of Numo::SFloat channels.
        def data
          @chunks.map { |c| c.empty? ? Numo::SFloat[] : Numo::SFloat.hstack(c) }
        end
      end
    end
  end
end
