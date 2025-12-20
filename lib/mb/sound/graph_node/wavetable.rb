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

        # The 2D Numo::NArray wavetable data used for sampling.
        attr_reader :table

        # Creates a new wavetable node.
        #
        # +:wavetable+ - A 2D Numo::NArray with time as columns and waves as
        #                rows, the filename of a previously saved wavetable, or
        #                a Hash of args to MB::Sound::Wavetable.load_wavetable.
        # +:number+ - A GraphNode to control the wave number (e.g. `3.constant`).
        # +:phase+ - A GraphNode to control the wave phase (e.g. `120.hz.ramp.at(1)`).
        def initialize(wavetable:, number:, phase:, sample_rate:)
          raise 'Number must be a GraphNode' unless number.is_a?(GraphNode)
          raise 'Phase must be a GraphNode' unless phase.is_a?(GraphNode)

          case wavetable
          when Hash
            filename = wavetable.fetch(:wavetable)
            args = wavetable.reject { |k, _| k == :wavetable }
            wavetable = MB::Sound::Wavetable.load_wavetable(filename, **args)

          when String
            wavetable = MB::Sound::Wavetable.load_wavetable(wavetable)

          else
            unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2
              raise 'Wavetable must be a 2D NArray or a wavetable filename' unless wavetable.ndim == 2
            end
          end

          @table = wavetable
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

          ::MB::Sound::Wavetable.wavetable_lookup(wavetable: @table, number: rho, phase: phi)
        end
      end
    end
  end
end
