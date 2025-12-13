module MB
  module Sound
    module GraphNode
      # Implementation of a wavetable waveshaper/synthesizer based on a wave
      # table stored as a 2D Numo::NArray.
      #
      # See bin/make_wavetable.rb.
      # See MB::Sound::Wavetable.
      # See MB::Sound::GraphNode#wavetable.
      class Wavetable
        include GraphNode
        include GraphNode::SampleRateHelper

        # Creates a new wavetable node.
        #
        # +:wavetable+ - A 2D Numo::NArray with time as columns and waves as
        #                rows, or a filename of a previously saved wavetable.
        # +:number+ - A GraphNode to control the wave number (e.g. `3.constant`).
        # +:phase+ - A GraphNode to control the wave phase (e.g. `120.hz.ramp.at(1)`).
        def initialize(wavetable:, number:, phase:, sample_rate:)
          raise 'Number must be a GraphNode' unless number.is_a?(GraphNode)
          raise 'Phase must be a GraphNode' unless phase.is_a?(GraphNode)

          wavetable = MB::Sound::Wavetable.load_wavetable(wavetable) if wavetable.is_a?(String)

          unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2
            raise 'Wavetable must be a 2D NArray or a wavetable filename'
          end

          @wavetable = wavetable
          @number = number
          @phase = phase
          @sample_rate = sample_rate
        end

        # The inputs to this node for wave number and wave phase.
        def sources
          {
            number: @number,
            phase: @phase,
          }
        end

        # Returns +count+ samples based on a wavetable lookup using the wave
        # number and phase from upstream graph sources given to the constructor.
        def sample(count)
          rho = @number.sample(count)
          phi = @phase.sample(count)
          return nil if rho.nil? || phi.nil? || rho.empty? || phi.empty?

          rho = MB::M.zpad(rho, count) if rho.length < count
          phi = MB::M.zpad(phi, count) if phi.length < count

          ::MB::Sound::Wavetable.wavetable_lookup(wavetable: @wavetable, number: rho, phase: phi)
        end
      end
    end
  end
end
